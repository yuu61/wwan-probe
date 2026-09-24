using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace WwanProbe
{
    // GNSS driver handle for the NMEA helper (the interface ACL requires an administrator).
    // It only switches NMEA logging and listens to it: Windows keeps the fix session
    // (Geolocator), so no native fix session is started alongside it.
    public sealed class GnssDevice : IDisposable
    {
        private const uint IoctlGetDeviceCapability = 0x220008;
        private const uint IoctlExecuteDriverCommand = 0x22000C;
        private const uint IoctlListenNmea = 0x22011C;
        private const uint ErrorIoPending = 997;
        private const uint WaitTimeout = 258;

        private readonly SafeFileHandle handle;

        [StructLayout(LayoutKind.Sequential)]
        private struct Overlapped
        {
            public UIntPtr Internal, InternalHigh;
            public uint Offset, OffsetHigh;
            public IntPtr Event;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle handle, uint code,
            IntPtr input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateEvent(IntPtr security, bool manual, bool initial, IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetOverlappedResult(SafeFileHandle handle, IntPtr overlapped,
            out uint transferred, bool wait);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CancelIoEx(SafeFileHandle handle, IntPtr overlapped);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        public GnssDevice(string devicePath)
        {
            // GENERIC_READ | GENERIC_WRITE, shared, OPEN_EXISTING, FILE_FLAG_OVERLAPPED.
            handle = CreateFile(devicePath, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Cannot open the GNSS device (Win32 error " + error + ").");
            }
            try
            {
                // GNSS_DEVICE_CAPABILITY: Size, Version, ... (604 bytes in DDI version 4).
                byte[] capability = Control(IoctlGetDeviceCapability, null, 604, 3000, out bool timedOut);
                if (timedOut) throw new TimeoutException("The GNSS driver did not report its capability.");
                if (capability.Length < 8) throw new InvalidOperationException("Truncated GNSS capability response.");
                DriverVersion = BitConverter.ToUInt32(capability, 4);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public uint DriverVersion { get; }

        // GNSS_SetNMEALogging. The driver cannot report the current value, so the caller
        // restores the default (disabled) when it finishes.
        public void SetNmeaLogging(bool enabled)
        {
            // GNSS_DRIVERCOMMAND_PARAM: 20-byte header, 512 reserved bytes, DWORD payload.
            byte[] command = new byte[536];
            BitConverter.GetBytes((uint)command.Length).CopyTo(command, 0);
            BitConverter.GetBytes(DriverVersion).CopyTo(command, 4);
            BitConverter.GetBytes((uint)13).CopyTo(command, 8); // GNSS_SetNMEALogging
            BitConverter.GetBytes((uint)4).CopyTo(command, 16);
            BitConverter.GetBytes(enabled ? (uint)255 : 0).CopyTo(command, 532);
            Control(IoctlExecuteDriverCommand, command, 0, 3000, out bool timedOut);
            if (timedOut) throw new TimeoutException("The GNSS driver did not accept the NMEA logging command.");
        }

        // One NMEA event: up to 256 characters of the NMEA stream (a sentence can span
        // events). Returns null when nothing arrives within timeoutMs.
        public string ReadNmea(uint timeoutMs)
        {
            byte[] data = Control(IoctlListenNmea, null, 8192, timeoutMs, out bool timedOut);
            if (timedOut) return null;
            // GNSS_EVENT: EventType (13 = NMEA data) at 8, union at 528; GNSS_NMEA_DATA header is 8 bytes.
            if (data.Length < 800 || BitConverter.ToUInt32(data, 8) != 13 || BitConverter.ToUInt32(data, 12) < 264)
                throw new InvalidOperationException("Invalid GNSS NMEA event.");
            int length = Array.IndexOf(data, (byte)0, 536, 256);
            return Encoding.ASCII.GetString(data, 536, (length < 0 ? 792 : length) - 536);
        }

        // Overlapped DeviceIoControl. A request still pending after timeoutMs is cancelled
        // and drained before its buffers are freed; cancellation depends on the driver.
        private byte[] Control(uint code, byte[] input, int outputSize, uint timeoutMs, out bool timedOut)
        {
            IntPtr source = IntPtr.Zero, output = IntPtr.Zero, overlapped = IntPtr.Zero, signal = IntPtr.Zero;
            timedOut = false;
            try
            {
                if (input != null && input.Length > 0)
                {
                    source = Marshal.AllocHGlobal(input.Length);
                    Marshal.Copy(input, 0, source, input.Length);
                }
                if (outputSize > 0)
                {
                    output = Marshal.AllocHGlobal(outputSize);
                    Marshal.Copy(new byte[outputSize], 0, output, outputSize);
                }
                signal = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
                if (signal == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                overlapped = Marshal.AllocHGlobal(Marshal.SizeOf<Overlapped>());
                Marshal.StructureToPtr(new Overlapped { Event = signal }, overlapped, false);
                bool ok = DeviceIoControl(handle, code, source, (uint)(input?.Length ?? 0),
                    output, (uint)outputSize, out uint returned, overlapped);
                int error = ok ? 0 : Marshal.GetLastWin32Error();
                if (!ok && error == ErrorIoPending)
                {
                    uint wait = WaitForSingleObject(signal, timeoutMs);
                    if (wait != 0)
                    {
                        timedOut = wait == WaitTimeout;
                        CancelIoEx(handle, overlapped);
                    }
                    ok = GetOverlappedResult(handle, overlapped, out returned, true);
                    error = ok ? 0 : Marshal.GetLastWin32Error();
                    // Completed before the cancellation took effect: keep the data.
                    if (ok) timedOut = false;
                }
                if (timedOut) return Array.Empty<byte>();
                if (!ok) throw new Win32Exception(error, string.Format("GNSS IOCTL 0x{0:X} failed (Win32 error {1}).", code, error));
                if (returned > outputSize) throw new InvalidOperationException("Invalid GNSS driver response size.");
                byte[] data = new byte[returned];
                if (data.Length > 0) Marshal.Copy(output, data, 0, data.Length);
                return data;
            }
            finally
            {
                if (overlapped != IntPtr.Zero) Marshal.FreeHGlobal(overlapped);
                if (signal != IntPtr.Zero) CloseHandle(signal);
                if (output != IntPtr.Zero) Marshal.FreeHGlobal(output);
                if (source != IntPtr.Zero) Marshal.FreeHGlobal(source);
            }
        }

        public void Dispose() => handle.Dispose();
    }
}
