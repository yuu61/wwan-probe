using System;
using Windows.Devices.Geolocation;

namespace WwanProbe
{
    // WinRT callbacks run without a PowerShell runspace. Keep only the latest report,
    // including during pause, so GPS acquisition never blocks LTE sampling or the UI.
    public sealed class GpsReading
    {
        public string Status { get; }
        public Geocoordinate Coordinate { get; }
        public string Error { get; }
        public GpsReading(string status, Geocoordinate coordinate, string error)
        {
            Status = status;
            Coordinate = coordinate;
            Error = error;
        }
    }

    public sealed class GpsReceiver : IDisposable
    {
        private readonly object gate = new object();
        private readonly Geolocator locator;
        private Geocoordinate coordinate;
        private string status = "Initializing";
        private string error;
        private bool disposed;

        public GpsReceiver()
        {
            locator = new Geolocator { DesiredAccuracy = PositionAccuracy.High, ReportInterval = 1000 };
            try
            {
                locator.StatusChanged += OnStatusChanged;
                locator.PositionChanged += OnPositionChanged;
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        private void OnPositionChanged(Geolocator sender, PositionChangedEventArgs args)
        {
            lock (gate)
            {
                if (disposed) return;
                try
                {
                    coordinate = args.Position.Coordinate;
                    status = "Ready";
                    error = null;
                }
                catch (Exception ex)
                {
                    coordinate = null;
                    error = ex.Message;
                }
            }
        }

        private void OnStatusChanged(Geolocator sender, StatusChangedEventArgs args)
        {
            lock (gate)
            {
                if (disposed) return;
                status = args.Status.ToString();
                if (args.Status != PositionStatus.Ready) coordinate = null;
            }
        }

        public GpsReading Read()
        {
            lock (gate) return new GpsReading(status, coordinate, error);
        }

        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
                coordinate = null;
                status = "NotInitialized";
            }
            // Do not hold the lock while WinRT drains callbacks during unsubscription.
            try { locator.PositionChanged -= OnPositionChanged; }
            finally { locator.StatusChanged -= OnStatusChanged; }
        }
    }
}
