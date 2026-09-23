using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using IPList.Core.Amnezia;
using IPList.Core.Catalog;
using IPList.Core.Networking;
using IPList.Core.Refresh;
using IPList.Core.State;
using IPList.Windows.Services;
using IPList.Windows.ViewModels;

namespace IPList.Windows;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly NativeFileDialogs _files = new();
    private readonly ClipboardService _clipboard = new();
    private readonly WindowsNotifications _notifications = new();
    private readonly ScheduleService _schedule;
    private TrayApplicationContext? _tray;
    private bool _syncing = true;
    private bool _allowExit;

    public MainWindow()
    {
        InitializeComponent();
        Pages.IsEnabled = false;
        var dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "IPList");
        _viewModel = new MainViewModel(new AppPersistenceCoordinator(new StateStore(), new AutosavedExportStore()),
            RefreshPipeline.Live(), dataDirectory);
        DataContext = _viewModel;
        CollectionViewSource.GetDefaultView(_viewModel.Services).GroupDescriptions.Add(new PropertyGroupDescription(nameof(ServiceRow.Category)));
        _viewModel.DataChanged += (_, _) => Dispatcher.Invoke(UpdateUi);
        _viewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(MainViewModel.RouteCount) or nameof(MainViewModel.AddressCount))
                Dispatcher.Invoke(() => ExportSummary.Text = $"{ModeTitle(_viewModel.Mode)} · {_viewModel.RouteCount} маршрутов · {_viewModel.AddressCount:N0} адресов");
            if (e.PropertyName == nameof(MainViewModel.IsBusy) && !_viewModel.IsBusy)
            {
                Dispatcher.Invoke(() =>
                {
                    Pages.IsEnabled = _viewModel.IsLoaded;
                    if (_viewModel.Error.Length > 0) Alert(_viewModel.Error);
                    else if (_viewModel.State.NotificationsEnabled) _notifications.Show(_tray?.Icon, "IPList", _viewModel.Status);
                });
            }
            else if (e.PropertyName == nameof(MainViewModel.IsBusy))
                Dispatcher.Invoke(() => Pages.IsEnabled = false);
        };
        _schedule = new ScheduleService(() => _viewModel.RefreshAsync());
        Loaded += async (_, _) =>
        {
            try { await _viewModel.LoadAsync(); SyncSettingsForm(); UpdateUi(); Pages.IsEnabled = true; }
            catch { Pages.IsEnabled = false; Alert("Не удалось прочитать локальное состояние. Исходный файл не изменён."); }
        };
    }

    private void UpdateUi()
    {
        if (!_viewModel.IsLoaded) return;
        _syncing = true;
        try
        {
            CatalogMode.SelectedIndex = SettingsMode.SelectedIndex = (int)_viewModel.Mode;
            RemainderCheck.IsChecked = _viewModel.State.RemaindersSelectedByMode.TryGetValue(_viewModel.Mode, out var remainder)
                ? remainder : _viewModel.State.SelectNewRemainders;
            ManualEnabledCheck.IsChecked = _viewModel.State.ManualEnabled;
            ExportSummary.Text = $"{ModeTitle(_viewModel.Mode)} · {_viewModel.RouteCount} маршрутов · {_viewModel.AddressCount:N0} адресов";
            LastCheckText.Text = "Последняя проверка: " + _viewModel.LastCheck;
            var selectedProfile = ProfileList.SelectedItem as string;
            ProfileList.ItemsSource = _viewModel.State.Profiles.Keys.OrderBy(x => x).ToArray();
            ProfileList.SelectedItem = selectedProfile;
            _schedule.Automatic = _viewModel.State.Automatic;
            _schedule.IntervalHours = _viewModel.State.IntervalHours;
            if (_viewModel.State.TrayEnabled && _tray is null)
                _tray = new TrayApplicationContext(() => Dispatcher.Invoke(ShowWindow),
                    () => Dispatcher.Invoke(() => _ = _viewModel.RefreshAsync()),
                    () => Dispatcher.Invoke(() => MessageBox.Show(_viewModel.Status, "IPList")),
                    () => Dispatcher.Invoke(ExitApplication));
            else if (!_viewModel.State.TrayEnabled && _tray is not null) { _tray.Dispose(); _tray = null; }
        }
        finally { _syncing = false; }
    }

    private void SyncSettingsForm()
    {
        var urls = _viewModel.State.SourceUrls;
        if (urls.Count == 4)
        {
            MetadataUrl.Text = urls[0]; TargetedUrl.Text = urls[1]; LiteUrl.Text = urls[2]; FullUrl.Text = urls[3];
        }
        AutomaticCheck.IsChecked = _viewModel.State.Automatic;
        IntervalBox.Text = _viewModel.State.IntervalHours.ToString();
        NotificationsCheck.IsChecked = _viewModel.State.NotificationsEnabled;
        TrayCheck.IsChecked = _viewModel.State.TrayEnabled;
        CloseToTrayCheck.IsChecked = _viewModel.CloseToTray;
    }

    private static string ModeTitle(ExportMode mode) => mode switch
    {
        ExportMode.Targeted => "Точечный обход",
        ExportMode.Lite => "Компактный IP-список (Lite)",
        _ => "Полный российский сегмент"
    };
    private void Alert(string message) => MessageBox.Show(this, message, "IPList", MessageBoxButton.OK, MessageBoxImage.Warning);
    private async Task TryAction(Func<Task> action)
    {
        try { await action(); }
        catch (Exception ex) { Alert(MainViewModel.SafeError(ex)); }
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_viewModel is not null) _viewModel.Search = SearchBox.Text;
    }
    private async void Mode_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || sender is not ComboBox box || box.SelectedItem is not ComboBoxItem item) return;
        if (Enum.TryParse<ExportMode>(item.Tag as string, out var mode))
            await TryAction(() => _viewModel.SetModeAsync(mode));
    }
    private async void Service_Changed(object sender, RoutedEventArgs e)
    {
        if (_syncing || sender is not CheckBox { Tag: string id } check) return;
        await TryAction(() => _viewModel.SelectServiceAsync(id, check.IsChecked == true));
    }
    private async void Remainder_Changed(object sender, RoutedEventArgs e)
    {
        if (!_syncing) await TryAction(() => _viewModel.SetRemainderAsync(RemainderCheck.IsChecked == true));
    }
    private async void SelectAll_Click(object sender, RoutedEventArgs e) => await TryAction(() => _viewModel.SelectAllAsync(true));
    private async void ClearAll_Click(object sender, RoutedEventArgs e) => await TryAction(() => _viewModel.SelectAllAsync(false));
    private async void SelectCategory_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string category }) await TryAction(() => _viewModel.SelectAllAsync(true, category));
    }
    private async void ClearCategory_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string category }) await TryAction(() => _viewModel.SelectAllAsync(false, category));
    }
    private async void ManualEnabled_Changed(object sender, RoutedEventArgs e)
    {
        if (!_syncing) await TryAction(() => _viewModel.SetManualEnabledAsync(ManualEnabledCheck.IsChecked == true));
    }
    private async void AddManual_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var (added, invalid) = await _viewModel.AddManualAsync(ManualInput.Text, ManualGroup.Text, ManualNote.Text);
            if (invalid.Count > 0) Alert($"Добавлено: {added}. Некорректные значения: {string.Join(", ", invalid.Take(20))}");
            if (added > 0) ManualInput.Clear();
        }
        catch (Exception ex) { Alert(MainViewModel.SafeError(ex)); }
    }
    private async void DeleteManual_Click(object sender, RoutedEventArgs e)
    {
        if (ManualGrid.SelectedItem is ManualRow row) await TryAction(() => _viewModel.RemoveManualAsync(row.Value));
    }
    private async void UpdateManual_Click(object sender, RoutedEventArgs e)
    {
        if (ManualGrid.SelectedItem is ManualRow row) await TryAction(() => _viewModel.UpdateManualAsync(row.Value, ManualGroup.Text, ManualNote.Text));
    }
    private void CopyManual_Click(object sender, RoutedEventArgs e)
    {
        var value = string.Join(Environment.NewLine, _viewModel.ManualRoutes.Select(x => x.Value));
        if (value.Length > 0 && !_clipboard.TryCopy(value)) Alert("Буфер обмена недоступен.");
    }
    private void CopySelectedManual_Click(object sender, RoutedEventArgs e)
    {
        if (ManualGrid.SelectedItem is ManualRow row && !_clipboard.TryCopy(row.Value)) Alert("Буфер обмена недоступен.");
    }
    private void ManualGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ManualGrid.SelectedItem is ManualRow row) { ManualGroup.Text = row.Group; ManualNote.Text = row.Note; }
    }
    private async void ImportJson_Click(object sender, RoutedEventArgs e)
    {
        var path = _files.OpenJson().FirstOrDefault();
        if (path is null) return;
        try
        {
            if (new FileInfo(path).Length > 4 * 1024 * 1024) throw new FormatException();
            using var doc = JsonDocument.Parse(await File.ReadAllBytesAsync(path));
            if (doc.RootElement.ValueKind != JsonValueKind.Array) throw new FormatException();
            var valid = new List<string>(); var issues = new List<string>(); var rowNumber = 0;
            foreach (var record in doc.RootElement.EnumerateArray())
            {
                rowNumber++;
                if (record.ValueKind != JsonValueKind.Object) { issues.Add($"Строка {rowNumber}: ожидается объект."); continue; }
                foreach (var name in new[] { "hostname", "ip", "ips" })
                {
                    if (!record.TryGetProperty(name, out var part)) continue;
                    string[] candidates = part.ValueKind == JsonValueKind.String ? [part.GetString() ?? ""] :
                        part.ValueKind == JsonValueKind.Array ? part.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString() ?? "").ToArray() : [];
                    foreach (var candidate in candidates)
                    {
                        if (candidate.Length == 0) continue;
                        if (IPv4Network.TryParse(candidate, out var route)) valid.Add(route.ToString());
                        else if (name != "hostname" || candidate.Contains('/') || candidate.Any(char.IsWhiteSpace))
                            issues.Add($"Строка {rowNumber}: поле {name} не содержит IPv4/CIDR.");
                    }
                }
            }
            var preview = new ImportPreviewWindow(valid.Distinct().ToArray(), issues) { Owner = this };
            if (preview.ShowDialog() == true && preview.Selected.Count > 0)
            {
                var result = await _viewModel.AddManualAsync(string.Join(" ", preview.Selected), ManualGroup.Text, ManualNote.Text);
                MessageBox.Show(this, $"Добавлено {result.Added} адресов.", "IPList");
            }
        }
        catch { Alert("Не удалось прочитать JSON. Проверьте формат AmneziaVPN."); }
    }

    private async void Pages_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (e.Source == Pages && Pages.SelectedIndex == 2 && _viewModel.IsLoaded)
            await TryAction(_viewModel.MarkChangesViewedAsync);
    }
    private void SaveJson_Click(object sender, RoutedEventArgs e)
    {
        try { if (!ConfirmFullFileExport()) return; var bytes = _viewModel.ExportJson(); var path = _files.Save("JSON|*.json", "amnezia-direct.json"); if (path is not null) File.WriteAllBytes(path, bytes); }
        catch (Exception ex) { Alert(MainViewModel.SafeError(ex)); }
    }
    private void CopyAllowed_Click(object sender, RoutedEventArgs e)
    {
        try { if (!_clipboard.TryCopy(_viewModel.ExportAllowedIPs())) Alert("Буфер обмена недоступен."); }
        catch (Exception ex) { Alert(MainViewModel.SafeError(ex)); }
    }
    private void SaveAllowed_Click(object sender, RoutedEventArgs e)
    {
        try { if (!ConfirmFullFileExport()) return; var text = _viewModel.ExportAllowedIPs(); var path = _files.Save("Текст|*.txt", "AllowedIPs.txt"); if (path is not null) File.WriteAllText(path, text, new UTF8Encoding(false)); }
        catch (Exception ex) { Alert(MainViewModel.SafeError(ex)); }
    }
    private void OpenExportFolder_Click(object sender, RoutedEventArgs e)
    {
        try { _files.OpenFolder(_viewModel.DataDirectory); }
        catch { Alert("Не удалось открыть папку приложения."); }
    }
    private async void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(IntervalBox.Text, out var hours)) { Alert("Интервал: целое число от 1 до 720 часов."); return; }
        await TryAction(() => _viewModel.SaveSettingsAsync(
            [MetadataUrl.Text, TargetedUrl.Text, LiteUrl.Text, FullUrl.Text],
            AutomaticCheck.IsChecked == true, hours, NotificationsCheck.IsChecked == true,
            TrayCheck.IsChecked == true, CloseToTrayCheck.IsChecked == true));
        SyncSettingsForm();
        _schedule.Reset();
    }
    private async void CheckSources_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var urls = MainViewModel.ParseUrls([MetadataUrl.Text, TargetedUrl.Text, LiteUrl.Text, FullUrl.Text]);
            var checks = new (string Name, Uri Url, bool Metadata)[]
            {
                ("Каталог", urls.Metadata, true), ("Точечный", urls.Targeted, false),
                ("Lite", urls.Lite, false), ("Full", urls.Full, false)
            };
            _viewModel.Diagnostics.Clear();
            var service = new SourceCheckService();
            foreach (var check in checks)
                _viewModel.Diagnostics.Add(await service.CheckAsync(check.Name, check.Url, check.Metadata, CancellationToken.None));
        }
        catch (Exception ex) { Alert(MainViewModel.SafeError(ex)); }
    }
    private async void SaveProfile_Click(object sender, RoutedEventArgs e) => await TryAction(() => _viewModel.SaveProfileAsync(ProfileName.Text));
    private async void ApplyProfile_Click(object sender, RoutedEventArgs e)
    {
        if (ProfileList.SelectedItem is string name) await TryAction(() => _viewModel.ApplyProfileAsync(name));
    }
    private async void DeleteProfile_Click(object sender, RoutedEventArgs e)
    {
        if (ProfileList.SelectedItem is string name) await TryAction(() => _viewModel.DeleteProfileAsync(name));
    }

    private async void ConfWizard_Click(object sender, RoutedEventArgs e)
    {
        var paths = _files.OpenConfigs();
        if (paths.Length == 0) return;
        try
        {
            var routes = _viewModel.RequireRoutes();
            if (!ConfirmFullFileExport()) return;
            var docs = new List<AmneziaConfigDocument>();
            foreach (var path in paths)
            {
                if (new FileInfo(path).Length > 2 * 1024 * 1024) throw new FormatException();
                docs.Add(AmneziaConfigDocument.Parse(await File.ReadAllBytesAsync(path)));
            }
            if (docs.Select(x => x.PeerCount).Distinct().Count() != 1) { Alert("У файлов различается число peer. Выберите файлы с одинаковой структурой."); return; }
            var wizard = new ConfigWizardWindow(docs[0].PeerCount, paths.Length) { Owner = this };
            if (wizard.ShowDialog() != true) return;
            var outputs = new List<(string Path, byte[] Bytes)>();
            for (var i = 0; i < paths.Length; i++)
            {
                var input = paths[i];
                var output = NextOutputPath(input, outputs.Select(x => x.Path));
                outputs.Add((output, docs[i].Render(wizard.PeerIndex, wizard.Operation, routes, wizard.PreserveIPv6)));
            }
            var written = new List<string>();
            try
            {
                foreach (var output in outputs)
                {
                    await using var stream = new FileStream(output.Path, FileMode.CreateNew, FileAccess.Write);
                    written.Add(output.Path);
                    await stream.WriteAsync(output.Bytes);
                }
            }
            catch
            {
                foreach (var path in written)
                {
                    try { File.Delete(path); }
                    catch (IOException) { /* Continue rolling back the remaining files. */ }
                    catch (UnauthorizedAccessException) { /* Continue rolling back the remaining files. */ }
                }
                throw;
            }
            MessageBox.Show(this, $"Создано файлов: {written.Count}. Исходные файлы не изменены.", "IPList");
        }
        catch { Alert("Не удалось создать .conf. Проверьте структуру, peer, маршруты и права на папку. Исходные файлы не изменены."); }
    }
    private bool ConfirmFullFileExport() => _viewModel.Mode != ExportMode.Full ||
        MessageBox.Show(this, "Full может создать очень большой список маршрутов. Продолжить для desktop/экспериментального использования?",
            "IPList", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes;
    private static string NextOutputPath(string input, IEnumerable<string> reserved)
    {
        var folder = Path.GetDirectoryName(input)!;
        var stem = Path.GetFileNameWithoutExtension(input);
        var output = Path.Combine(folder, stem + "-iplist.conf");
        for (var n = 2; File.Exists(output) || reserved.Contains(output, StringComparer.OrdinalIgnoreCase) || string.Equals(output, input, StringComparison.OrdinalIgnoreCase); n++)
            output = Path.Combine(folder, $"{stem}-iplist-{n}.conf");
        return output;
    }
    private void ShowWindow() { Show(); WindowState = WindowState.Normal; Activate(); }
    private void ExitApplication() { _allowExit = true; Close(); }
    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (!_allowExit && _viewModel.IsLoaded && _viewModel.State.TrayEnabled && _viewModel.CloseToTray)
        { e.Cancel = true; Hide(); return; }
        _schedule.Dispose(); _tray?.Dispose();
    }
}
