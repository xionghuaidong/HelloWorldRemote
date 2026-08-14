using System;
using System.Runtime.InteropServices;
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

        private sealed class WaitContext : ApplicationContext
        {
            private readonly ShutdownWindow window;
            private readonly Timer timeoutTimer;
            private readonly Timer injectedEventTimer;
            private readonly string injectedEvent;
            private bool completed;

            internal WaitContext(int seconds, string injectedEvent)
            {
                window = new ShutdownWindow(this);

                timeoutTimer = new Timer { Interval = checked(seconds * 1000) };
                timeoutTimer.Tick += OnTimeout;
                timeoutTimer.Start();

                if (injectedEvent != "none")
                {
                    this.injectedEvent = injectedEvent;
                    injectedEventTimer = new Timer { Interval = 1 };
                    injectedEventTimer.Tick += OnInjectedEvent;
                    injectedEventTimer.Start();
                }
            }

            internal string Result { get; private set; }

            internal void Complete(string result)
            {
                if (completed)
                {
                    return;
                }

                completed = true;
                Result = result;
                timeoutTimer.Stop();
                if (injectedEventTimer != null)
                {
                    injectedEventTimer.Stop();
                }
                ExitThread();
            }

            private void OnTimeout(object sender, EventArgs e)
            {
                Complete("timeout");
            }

            private void OnInjectedEvent(object sender, EventArgs e)
            {
                injectedEventTimer.Stop();
                window.PostInjectedEvent(injectedEvent);
            }

            protected override void Dispose(bool disposing)
            {
                if (disposing)
                {
                    timeoutTimer.Tick -= OnTimeout;
                    timeoutTimer.Dispose();
                    if (injectedEventTimer != null)
                    {
                        injectedEventTimer.Tick -= OnInjectedEvent;
                        injectedEventTimer.Dispose();
                    }
                    window.Dispose();
                }
                base.Dispose(disposing);
            }
        }

        private sealed class ShutdownWindow : NativeWindow, IDisposable
        {
            private const int WmQueryEndSession = 0x0011;
            private const int WmInjectedOrdinary = 0x8001;
            private readonly WaitContext context;

            internal ShutdownWindow(WaitContext context)
            {
                this.context = context;
                CreateHandle(new CreateParams { Caption = "UU Remote shutdown waiter" });
            }

            internal void PostInjectedEvent(string injectedEvent)
            {
                int message = injectedEvent == "shutdown" ? WmQueryEndSession : WmInjectedOrdinary;
                if (!PostMessage(Handle, message, IntPtr.Zero, IntPtr.Zero))
                {
                    throw new InvalidOperationException("Unable to inject watcher event");
                }
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == WmQueryEndSession)
                {
                    m.Result = new IntPtr(1);
                    context.Complete("shutdown/restart");
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
            if (injectedEvent != "none" && injectedEvent != "ordinary" && injectedEvent != "shutdown")
                throw new ArgumentException("Unsupported injected event", nameof(injectedEvent));
            using (var context = new WaitContext(seconds, injectedEvent))
            {
                Application.Run(context);
                return context.Result;
            }
        }
    }
}
