using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace IPList.Windows.Services;

public sealed class NativeFileDialogs
{
    public string[] OpenJson()
    {
        var dialog = new OpenFileDialog { Filter = "Amnezia JSON|*.json", Multiselect = false };
        return dialog.ShowDialog() == true ? [dialog.FileName] : [];
    }

    public string[] OpenConfigs()
    {
        var dialog = new OpenFileDialog { Filter = "AmneziaWG (*.conf)|*.conf", Multiselect = true };
        return dialog.ShowDialog() == true ? dialog.FileNames : [];
    }

    public string? Save(string filter, string defaultName)
    {
        var dialog = new SaveFileDialog { Filter = filter, FileName = defaultName, AddExtension = true };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    }

    public void OpenFolder(string folder)
    {
        Directory.CreateDirectory(folder);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }
}

public sealed class ClipboardService
{
    public bool TryCopy(string text)
    {
        try { Clipboard.SetText(text); return true; }
        catch { return false; }
    }
}

public sealed class WindowsNotifications
{
    public void Show(Forms.NotifyIcon? icon, string title, string message)
    {
        try { icon?.ShowBalloonTip(5000, title, message, Forms.ToolTipIcon.Info); }
        catch { /* Notifications are optional. */ }
    }
}

public sealed class ScheduleService : IDisposable
{
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly Func<Task> _refresh;
    private DateTimeOffset _lastAttempt = DateTimeOffset.UtcNow;
    public ScheduleService(Func<Task> refresh)
    {
        _refresh = refresh;
        _timer.Tick += OnTick;
        _timer.Start();
    }

    public bool Automatic { get; set; }
    public int IntervalHours { get; set; } = 24;
    private async void OnTick(object? sender, EventArgs e)
    {
        if (!Automatic || DateTimeOffset.UtcNow - _lastAttempt < TimeSpan.FromHours(Math.Clamp(IntervalHours, 1, 720))) return;
        _lastAttempt = DateTimeOffset.UtcNow;
        await _refresh();
    }
    public void Reset() => _lastAttempt = DateTimeOffset.UtcNow;
    public void Dispose() => _timer.Stop();
}

public sealed class TrayApplicationContext : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly System.Drawing.Icon _brandIcon;
    private readonly Stream _iconStream;
    public TrayApplicationContext(Action open, Action refresh, Action status, Action exit)
    {
        _iconStream = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/AppIcon.ico"))?.Stream
            ?? throw new FileNotFoundException("Не найден значок IPList.");
        _brandIcon = new System.Drawing.Icon(_iconStream);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Открыть", null, (_, _) => open());
        menu.Items.Add("Проверить сейчас", null, (_, _) => refresh());
        menu.Items.Add("Статус", null, (_, _) => status());
        menu.Items.Add("Выход", null, (_, _) => exit());
        _icon = new Forms.NotifyIcon
        {
            Icon = _brandIcon,
            Text = "IPList",
            ContextMenuStrip = menu,
            Visible = true
        };
        _icon.DoubleClick += (_, _) => open();
    }
    public Forms.NotifyIcon Icon => _icon;
    public void Dispose() { _icon.Visible = false; _icon.Dispose(); _brandIcon.Dispose(); _iconStream.Dispose(); }
}
