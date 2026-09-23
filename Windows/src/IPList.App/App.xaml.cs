using System.Windows;

namespace IPList.Windows;

public partial class App : Application
{
    private Mutex? _instanceMutex;
    private bool _ownsMutex;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _instanceMutex = new Mutex(true, @"Local\IPList.Windows.State", out var firstInstance);
        _ownsMutex = firstInstance;
        if (!firstInstance)
        {
            MessageBox.Show("IPList уже запущен. Откройте его через значок в области уведомлений.", "IPList");
            Shutdown();
            return;
        }
        MainWindow = new MainWindow();
        MainWindow.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_ownsMutex) _instanceMutex?.ReleaseMutex();
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }
}
