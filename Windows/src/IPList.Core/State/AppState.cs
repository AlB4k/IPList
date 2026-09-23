using IPList.Core.Catalog;
using IPList.Core.Networking;
using IPList.Core.Refresh;

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
    public Dictionary<ExportMode, List<string>> SelectedServiceIdsByMode { get; set; } = [];
    public Dictionary<ExportMode, bool> RemaindersSelectedByMode { get; set; } = [];
    public Dictionary<ExportMode, bool> SelectionInitializedByMode { get; set; } = [];
    public ServiceCatalog? Catalog { get; set; }
    public List<CatalogService> LegacyServices { get; set; } = [];
    public bool SelectNewServices { get; set; } = true;
    public bool SelectNewRemainders { get; set; } = true;
    public Dictionary<ExportMode, Dictionary<string, List<IPv4Network>>> MatchedRoutesByMode { get; set; } = [];
    public Dictionary<ExportMode, List<IPv4Network>> UnassignedRoutesByMode { get; set; } = [];
    public Dictionary<ExportMode, SourceSnapshot> SourceSnapshots { get; set; } = [];
    public EnrichmentSnapshot? Evidence { get; set; }
    public List<MatchDiagnostics> MigrationDiagnostics { get; set; } = [];
    public List<MatchDiagnostics> LastDiagnostics { get; set; } = [];
    public DateTimeOffset? LastCheckAt { get; set; }
    public DateTimeOffset? LastSuccessfulRefreshAt { get; set; }
    public List<string> SourceUrls { get; set; } = IPList.Core.Refresh.RefreshSourceUrls.Default.ToStringList();
    public int IntervalHours { get; set; } = 24;
    public bool Automatic { get; set; }
    public bool TrayEnabled { get; set; } = true;
    public bool CloseToTray { get; set; } = true;
    public bool NotificationsEnabled { get; set; } = true;
    public bool ChangesViewed { get; set; } = true;
    public List<ChangeRecord> History { get; set; } = [];

    public IReadOnlyList<IPv4Network> ExportRoutes(ExportMode mode)
    {
        var selectedIds = SelectedServiceIdsByMode.TryGetValue(mode, out var ids) ? ids : SelectedServiceIds;
        var initialized = SelectionInitializedByMode.GetValueOrDefault(mode) || selectedIds.Count > 0;
        var routes = new List<IPv4Network>();
        if (MatchedRoutesByMode.TryGetValue(mode, out var services))
            foreach (var (id, owned) in services)
                if (!initialized || selectedIds.Contains(id, StringComparer.OrdinalIgnoreCase)) routes.AddRange(owned);
        if (UnassignedRoutesByMode.TryGetValue(mode, out var remainder) &&
            (!RemaindersSelectedByMode.TryGetValue(mode, out var include) ? SelectNewRemainders : include)) routes.AddRange(remainder);
        if (ManualEnabled)
            foreach (var manual in ManualRoutes)
                if (IPv4Network.TryParse(manual.Value, out var route)) routes.Add(route);
                else throw new FormatException("Invalid saved manual IPv4 route.");
        return RouteSet.Normalize(routes);
    }

    public void SetSelection(ExportMode mode, string serviceId, bool selected)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(serviceId);
        if (!SelectedServiceIdsByMode.TryGetValue(mode, out var ids))
        {
            ids = SelectedServiceIds.Count > 0 ? SelectedServiceIds.ToList() :
                SelectionInitializedByMode.GetValueOrDefault(mode) ? [] :
                MatchedRoutesByMode.TryGetValue(mode, out var services) ? services.Keys.ToList() : [];
            SelectedServiceIdsByMode[mode] = ids;
        }
        SelectionInitializedByMode[mode] = true;
        ids.RemoveAll(id => id.Equals(serviceId, StringComparison.OrdinalIgnoreCase));
        if (selected) ids.Add(serviceId);
    }

    public void SetRemainderSelection(ExportMode mode, bool selected) => RemaindersSelectedByMode[mode] = selected;

    public void ApplyProfile(string name)
    {
        if (!Profiles.TryGetValue(name, out var profile)) throw new KeyNotFoundException("Profile was not found.");
        foreach (var mode in profile.Modes)
        {
            SelectedServiceIdsByMode[mode] = profile.SelectedServiceIds.ToList();
            SelectionInitializedByMode[mode] = true;
        }
        if (profile.Modes.Count > 0 && !profile.Modes.Contains(Mode)) Mode = profile.Modes.Order().First();
        ManualEnabled = profile.IncludeManual;
    }

    public void RecordChange(ChangeRecord change)
    {
        History.Insert(0, change);
        if (History.Count > 100) History.RemoveRange(100, History.Count - 100);
        ChangesViewed = false;
    }

    public void ApplyRefresh(RefreshTransaction transaction)
    {
        var previous = MatchedRoutesByMode;
        if (SelectedServiceIds.Count > 0)
            foreach (var mode in transaction.MatchedCatalog.RoutesByMode.Keys)
                if (!SelectedServiceIdsByMode.ContainsKey(mode))
                {
                    SelectedServiceIdsByMode[mode] = SelectedServiceIds.ToList();
                    SelectionInitializedByMode[mode] = true;
                }
        var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (Catalog is not null) known.UnionWith(Catalog.Services.Select(service => service.Id));
        known.UnionWith(LegacyServices.Select(service => service.Id));
        known.UnionWith(SelectedServiceIds);
        foreach (var services in previous.Values) known.UnionWith(services.Keys);
        var hasHistoricalInventory = Catalog is not null || LegacyServices.Count > 0 || previous.Count > 0;
        if (SelectNewServices)
            foreach (var (mode, services) in transaction.MatchedCatalog.RoutesByMode)
                if (SelectionInitializedByMode.GetValueOrDefault(mode) &&
                    SelectedServiceIdsByMode.TryGetValue(mode, out var ids))
                {
                    if (hasHistoricalInventory)
                        foreach (var id in services.Keys)
                            if (!known.Contains(id) && !ids.Contains(id, StringComparer.OrdinalIgnoreCase)) ids.Add(id);
                }
        Catalog = transaction.MatchedCatalog.Catalog;
        MatchedRoutesByMode = transaction.MatchedCatalog.RoutesByMode.ToDictionary(
            pair => pair.Key, pair => pair.Value.ToDictionary(
                service => service.Key, service => service.Value.ToList(), StringComparer.OrdinalIgnoreCase));
        UnassignedRoutesByMode = transaction.MatchedCatalog.UnassignedRoutes.ToDictionary(
            pair => pair.Key, pair => pair.Value.ToList());
        SourceSnapshots = transaction.SourceSnapshots.ToDictionary(pair => pair.Key, pair => pair.Value);
        Evidence = transaction.Enrichment;
        LastDiagnostics = transaction.Diagnostics.ToList();
        LastCheckAt = transaction.CompletedAt;
        LastSuccessfulRefreshAt = transaction.CompletedAt;
    }
}

public sealed record ChangeRecord(DateTimeOffset At, string Reason, int Added, int Removed,
    IReadOnlyList<string> AddedRoutes = null!, IReadOnlyList<string> RemovedRoutes = null!);

internal static class RefreshSourceUrlExtensions
{
    public static List<string> ToStringList(this IPList.Core.Refresh.RefreshSourceUrls urls) =>
        [urls.Metadata.ToString(), urls.Targeted.ToString(), urls.Lite.ToString(), urls.Full.ToString()];
}
