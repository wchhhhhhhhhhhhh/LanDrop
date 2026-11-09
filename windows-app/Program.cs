using System;
using System.IO;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace LanDrop;

/// 自定义入口：默认生成的 Main 在 WinUI 初始化失败时没有任何输出，
/// 这里把每一步写进 boot.log，便于定位是 WinRT 激活、Application.Start 还是 XAML 加载的问题。
public static class Program
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [STAThread]
    private static void Main(string[] args)
    {
        // PerMonitorV2：不依赖 app.manifest（自定义清单会让 WinUI 引导失败）
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
        Log("main start");
        try
        {
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Log("com wrappers ok");

            Application.Start(p =>
            {
                Log("application.start callback");
                try
                {
                    var queue = DispatcherQueue.GetForCurrentThread();
                    SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(queue));
                    var app = new App();
                    Log("app constructed");
                }
                catch (Exception ex)
                {
                    Log("app ctor failed: " + ex);
                    throw;
                }
            });
            Log("application.start returned");
        }
        catch (Exception ex)
        {
            Log("main failed: " + ex);
            throw;
        }
    }

    public static void Log(string message)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanDrop");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "boot.log"), $"{DateTime.Now:HH:mm:ss.fff} {message}\n");
        }
        catch { }
    }
}
