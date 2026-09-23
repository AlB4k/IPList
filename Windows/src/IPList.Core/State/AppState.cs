using System.Text.Json.Serialization;
using IPList.Core.Catalog;

namespace IPList.Core.State;

public sealed record ManualRoute(string Value, string? Group = null, string? Note = null);
public sealed record SelectionProfile(string Name, IReadOnlySet<string> SelectedServiceIds,
    IReadOnlySet<ExportMode> Modes, bool IncludeManual);

public sealed class AppState
{
    public int SchemaVersion { get; set; } = 1;
    public ExportMode Mode { get; set; } = ExportMode.Targeted;
    public bool ManualEnabled { get; set; } = true;
    public List<ManualRoute> ManualRoutes { get; set; } = [];
    public Dictionary<string, SelectionProfile> Profiles { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public List<string> SelectedServiceIds { get; set; } = [];
    public List<string> SelectedRemainders { get; set; } = [];
    public List<string> SourceUrls { get; set; } = IPList.Core.Refresh.RefreshSourceUrls.Default.ToStringList();
    public int IntervalHours { get; set; } = 24;
    public bool Automatic { get; set; }
    public bool TrayEnabled { get; set; } = true;
    public bool NotificationsEnabled { get; set; } = true;
    public bool ChangesViewed { get; set; } = true;
    public List<ChangeRecord> History { get; set; } = [];
}

public sealed record ChangeRecord(DateTimeOffset At, string Reason, int Added, int Removed,
    IReadOnlyList<string> AddedRoutes = null!, IReadOnlyList<string> RemovedRoutes = null!);

internal static class RefreshSourceUrlExtensions
{
    public static List<string> ToStringList(this IPList.Core.Refresh.RefreshSourceUrls urls) =>
        [urls.Metadata.ToString(), urls.Targeted.ToString(), urls.Lite.ToString(), urls.Full.ToString()];
}
