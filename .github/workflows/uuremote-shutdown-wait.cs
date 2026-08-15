using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace UURemote
{
    public static class ShutdownWaiter
    {
        // Pre-C# 6 binds these overloads; modern compilers use the nameof operator, preserving parameter names in both cases.
        private static string nameof(int value)
        {
            return "seconds";
        }

        private static string nameof(string value)
        {
            return "injectedEvent";
        }

        private sealed class ShutdownWindow : NativeWindow, IDisposable
        {
            private const int WmQueryEndSession = 0x0011;
            private const int WmInjectedOrdinary = 0x8001;
            private const long EndSessionLogoff = 0x80000000L;
            internal ShutdownWindow()
            {
                CreateHandle(new CreateParams { Caption = "UU Remote shutdown waiter" });
            }

            internal string Result { get; private set; }

            internal void PostInjectedEvent(string injectedEvent)
            {
                bool queryEndSession = injectedEvent == "shutdown" || injectedEvent == "logout";
                int message = queryEndSession ? WmQueryEndSession : WmInjectedOrdinary;
                IntPtr longParameter = injectedEvent == "logout"
                    ? new IntPtr(unchecked((int)EndSessionLogoff))
                    : IntPtr.Zero;
                if (!PostMessage(Handle, message, IntPtr.Zero, longParameter))
                {
                    throw new InvalidOperationException("Unable to inject watcher event");
                }
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == WmQueryEndSession)
                {
                    m.Result = new IntPtr(1);
                    if ((m.LParam.ToInt64() & EndSessionLogoff) == 0)
                    {
                        Result = "shutdown/restart";
                    }
                    return;
                }

                if (m.Msg == WmInjectedOrdinary)
                {
                    m.Result = IntPtr.Zero;
                    return;
                }

                base.WndProc(ref m);
            }

            public void Dispose()
            {
                DestroyHandle();
            }

            [DllImport("user32.dll", SetLastError = true)]
            private static extern bool PostMessage(
                IntPtr windowHandle,
                int message,
                IntPtr wordParameter,
                IntPtr longParameter);
        }

        public static string Run(int seconds, string injectedEvent)
        {
            if (seconds < 1) throw new ArgumentOutOfRangeException(nameof(seconds));
            if (injectedEvent != "none" && injectedEvent != "ordinary" &&
                injectedEvent != "logout" && injectedEvent != "shutdown")
                throw new ArgumentException("Unsupported injected event", nameof(injectedEvent));
            long timeoutMilliseconds = checked(seconds * 1000L);
            using (var window = new ShutdownWindow())
            {
                if (injectedEvent != "none")
                {
                    window.PostInjectedEvent(injectedEvent);
                }

                var stopwatch = Stopwatch.StartNew();
                while (window.Result == null && stopwatch.ElapsedMilliseconds < timeoutMilliseconds)
                {
                    Application.DoEvents();
                    if (window.Result == null)
                    {
                        long remainingMilliseconds = timeoutMilliseconds - stopwatch.ElapsedMilliseconds;
                        if (remainingMilliseconds > 0)
                        {
                            Thread.Sleep((int)Math.Min(50L, remainingMilliseconds));
                        }
                    }
                }
                return window.Result ?? "timeout";
            }
        }
    }
}
