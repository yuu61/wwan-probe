using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace WwanProbe
{
    public sealed class GnssIoResult
    {
        public int Error { get; set; }
        public bool TimedOut { get; set; }
        public byte[] Data { get; set; }
    }

    // Native GNSS driver handle for NMEA logging/listening only. Windows keeps the fix
    // session (Geolocator); never start a second native fix session alongside it.
    public sealed class GnssDevice : IDisposable
    {
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
            handle = CreateFile(devicePath, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
        }

        public GnssIoResult Query(uint code, byte[] input, int outputSize, uint timeout)
        {
            if (outputSize < 0 || outputSize > 65536) throw new ArgumentOutOfRangeException(nameof(outputSize));
            IntPtr source = IntPtr.Zero, output = IntPtr.Zero, overlapped = IntPtr.Zero, signal = IntPtr.Zero;
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
                bool timedOut = false;
                if (!ok && error == 997) // ERROR_IO_PENDING
                {
                    uint wait = WaitForSingleObject(signal, timeout);
                    if (wait != 0)
                    {
                        timedOut = wait == 258;
                        CancelIoEx(handle, overlapped);
                    }
                    // Drain cancellation before releasing buffers still owned by the kernel.
                    // Cancellation completion depends on the driver honoring CancelIoEx.
                    ok = GetOverlappedResult(handle, overlapped, out returned, true);
                    error = ok ? 0 : Marshal.GetLastWin32Error();
                }
                if (ok && returned > outputSize) throw new InvalidOperationException("Invalid driver response size.");
                byte[] data = new byte[ok ? checked((int)returned) : 0];
                if (data.Length > 0) Marshal.Copy(output, data, 0, data.Length);
                return new GnssIoResult { Error = error, TimedOut = timedOut, Data = data };
            }
            finally
            {
                if (overlapped != IntPtr.Zero) Marshal.FreeHGlobal(overlapped);
                if (signal != IntPtr.Zero) CloseHandle(signal);
                if (output != IntPtr.Zero) Marshal.FreeHGlobal(output);
                if (source != IntPtr.Zero) Marshal.FreeHGlobal(source);
            }
        }

        public GnssIoResult SetNmeaLogging(uint version, bool enabled)
        {
            // GNSS_DRIVERCOMMAND_PARAM: 20-byte header, 512 reserved bytes, DWORD payload.
            byte[] command = new byte[536];
            BitConverter.GetBytes((uint)command.Length).CopyTo(command, 0);
            BitConverter.GetBytes(version).CopyTo(command, 4);
            BitConverter.GetBytes((uint)13).CopyTo(command, 8); // GNSS_SetNMEALogging
            BitConverter.GetBytes((uint)4).CopyTo(command, 16);
            BitConverter.GetBytes(enabled ? (uint)255 : 0).CopyTo(command, 532);
            return Query(0x22000C, command, 0, 3000);
        }

        public void Dispose() => handle.Dispose();
    }
}
