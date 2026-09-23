using System.Windows;

namespace IPList.Windows;

public partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();
    private void Refresh_Click(object sender, RoutedEventArgs e) => MessageBox.Show("Обновление источников будет выполнено через Core pipeline.", "IPList");
}
