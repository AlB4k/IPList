using System.Windows;
using System.Windows.Controls;
using IPList.Core.Amnezia;

namespace IPList.Windows.ViewModels;

public sealed class ImportPreviewWindow : Window
{
    private readonly ListBox _routes = new() { SelectionMode = SelectionMode.Multiple };
    public IReadOnlyList<string> Selected { get; private set; } = [];

    public ImportPreviewWindow(IReadOnlyList<string> routes, IReadOnlyList<string> invalidRows)
    {
        Title = "Предпросмотр импорта JSON";
        Width = 520; Height = 530; MinWidth = 360; MinHeight = 350;
        var root = new DockPanel { Margin = new Thickness(14) };
        Content = root;
        var title = new TextBlock
        {
            Text = $"Найдено IPv4/CIDR: {routes.Count}. Пропущено некорректных значений: {invalidRows.Count}. Выберите строки для добавления.",
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8)
        };
        DockPanel.SetDock(title, Dock.Top); root.Children.Add(title);
        if (invalidRows.Count > 0)
        {
            var details = new TextBlock
            {
                Text = string.Join(Environment.NewLine, invalidRows.Take(8)) + (invalidRows.Count > 8 ? Environment.NewLine + "…" : ""),
                Foreground = System.Windows.Media.Brushes.Firebrick, TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 8)
            };
            DockPanel.SetDock(details, Dock.Top); root.Children.Add(details);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(buttons, Dock.Bottom); root.Children.Add(buttons);
        var add = new Button { Content = "Добавить выбранные", Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(4) };
        add.Click += (_, _) => { Selected = _routes.SelectedItems.Cast<string>().ToArray(); DialogResult = true; };
        buttons.Children.Add(add);
        var cancel = new Button { Content = "Отмена", Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(4) };
        cancel.Click += (_, _) => DialogResult = false;
        buttons.Children.Add(cancel);
        _routes.ItemsSource = routes;
        root.Children.Add(_routes);
        Loaded += (_, _) => _routes.SelectAll();
    }
}

public sealed class ConfigWizardWindow : Window
{
    private readonly ComboBox _peer = new();
    private readonly ComboBox _operation = new();
    private readonly CheckBox _preserveIpv6 = new() { Content = "Сохранять IPv6", IsChecked = true };
    public int PeerIndex => _peer.SelectedIndex;
    public AllowedIPsOperation Operation => (AllowedIPsOperation)_operation.SelectedIndex;
    public bool PreserveIPv6 => _preserveIpv6.IsChecked == true;

    public ConfigWizardWindow(int peerCount, int fileCount)
    {
        Title = "Создать AmneziaWG .conf";
        Width = 480; Height = 300; ResizeMode = ResizeMode.NoResize;
        var panel = new StackPanel { Margin = new Thickness(18) };
        Content = panel;
        panel.Children.Add(new TextBlock { Text = $"Файлов: {fileCount}. Выберите peer и способ изменения AllowedIPs.", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = "Peer (по порядку в файле)", Margin = new Thickness(0, 12, 0, 3) });
        for (var i = 0; i < peerCount; i++) _peer.Items.Add($"Peer {i + 1}");
        _peer.SelectedIndex = 0; panel.Children.Add(_peer);
        panel.Children.Add(new TextBlock { Text = "Операция", Margin = new Thickness(0, 12, 0, 3) });
        _operation.Items.Add("Добавить к существующим");
        _operation.Items.Add("Заменить выбранными");
        _operation.Items.Add("Пустить выбранное мимо VPN");
        _operation.SelectedIndex = 0; panel.Children.Add(_operation);
        panel.Children.Add(_preserveIpv6);
        var create = new Button { Content = "Создать рядом с исходным файлом", Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(0, 12, 0, 0) };
        create.Click += (_, _) => DialogResult = true;
        panel.Children.Add(create);
    }
}
