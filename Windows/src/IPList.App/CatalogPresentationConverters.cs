using System.Collections;
using System.Globalization;
using System.Windows.Data;
using IPList.Windows.ViewModels;

namespace IPList.Windows;

public sealed class CategorySelectionTextConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture)
    {
        var rows = (values.FirstOrDefault() as IEnumerable)?.Cast<object>().OfType<ServiceRow>().ToArray() ?? [];
        return $"{rows.Count(row => row.Selected)}/{rows.Length}";
    }

    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class CategoryAllSelectedConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture)
    {
        var rows = (values.FirstOrDefault() as IEnumerable)?.Cast<object>().OfType<ServiceRow>().ToArray() ?? [];
        return rows.Length > 0 && rows.All(row => row.Selected);
    }

    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class CategoryGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        (value as string) switch
        {
            "Банки и финансы" => "\uE80F",
            "Безопасность" => "\uE72E",
            "Государство" => "\uE7F4",
            "Карты" => "\uE707",
            "Магазины" or "Маркетплейсы" => "\uE719",
            "Медицина" => "\uE95E",
            "Поиск и технологии" => "\uE721",
            "Почта" => "\uE715",
            "Развлечения" => "\uE714",
            "СМИ" => "\uE8A5",
            "Социальные сети" => "\uE716",
            "Транспорт и путешествия" => "\uE7F4",
            _ => "\uE8B7"
        };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
