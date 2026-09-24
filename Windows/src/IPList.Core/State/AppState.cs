using IPList.Core.Catalog;
using IPList.Core.Networking;
using IPList.Core.Refresh;

namespace IPList.Core.State;

public sealed record ManualRoute(string Value, string? Group = null, string? Note = null, bool IsIncludedInExport = true);
public sealed record SelectionProfile(string Name, HashSet<string> SelectedServiceIds,
    HashSet<ExportMode> Modes, bool IncludeManual, bool? IncludeRemainders = null);

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
                if (manual.IsIncludedInExport && IPv4Network.TryParse(manual.Value, out var route)) routes.Add(route);
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
            if (profile.IncludeRemainders is { } includeRemainders)
                RemaindersSelectedByMode[mode] = includeRemainders;
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
        var previousServices = (Catalog?.Services ?? []).Concat(LegacyServices)
            .GroupBy(service => service.Id, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First()).ToArray();
        var currentServices = transaction.MatchedCatalog.Catalog.Services;
        var currentIds = currentServices.Select(service => service.Id)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var previousIds = previousServices.Select(service => service.Id)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var oldByToken = previousServices.SelectMany(service => IdentityTokens(service)
            .Select(token => (Token: token, Service: service)))
            .GroupBy(item => item.Token, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.Select(item => item.Service.Id)
                .Distinct(StringComparer.OrdinalIgnoreCase).ToArray(), StringComparer.OrdinalIgnoreCase);
        var newByToken = currentServices.SelectMany(service => IdentityTokens(service)
            .Select(token => (Token: token, Service: service)))
            .GroupBy(item => item.Token, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.Select(item => item.Service.Id)
                .Distinct(StringComparer.OrdinalIgnoreCase).ToArray(), StringComparer.OrdinalIgnoreCase);
        var renameCandidates = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
        var unambiguousEvidence = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var service in currentServices.Where(service => !previousIds.Contains(service.Id)))
        {
            var candidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var hasHistoricalIdentity = false;
            var allMatchesUnique = true;
            foreach (var token in IdentityTokens(service))
            {
                if (!oldByToken.TryGetValue(token, out var oldIds)) continue;
                hasHistoricalIdentity = true;
                candidates.UnionWith(oldIds.Where(id => !currentIds.Contains(id)));
                if (oldIds.Length != 1 || newByToken[token].Length != 1 || currentIds.Contains(oldIds[0]))
                    allMatchesUnique = false;
            }
            if (hasHistoricalIdentity) renameCandidates[service.Id] = candidates;
            if (hasHistoricalIdentity && allMatchesUnique) unambiguousEvidence.Add(service.Id);
        }
        var oldCandidateCounts = renameCandidates.Values.SelectMany(ids => ids)
            .GroupBy(id => id, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.OrdinalIgnoreCase);
        var recovered = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var ambiguous = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (newId, candidates) in renameCandidates)
        {
            if (candidates.Count == 1 && unambiguousEvidence.Contains(newId) &&
                oldCandidateCounts[candidates.Single()] == 1)
                recovered[newId] = candidates.Single();
            else ambiguous.Add(newId);
        }
        if (SelectedServiceIds.Count > 0)
            foreach (var mode in transaction.MatchedCatalog.RoutesByMode.Keys)
                if (!SelectedServiceIdsByMode.ContainsKey(mode))
                {
                    SelectedServiceIdsByMode[mode] = SelectedServiceIds.ToList();
                    SelectionInitializedByMode[mode] = true;
                }
        var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        known.UnionWith(previousIds);
        known.UnionWith(LegacyServices.Select(service => service.Id));
        known.UnionWith(SelectedServiceIds);
        foreach (var services in previous.Values) known.UnionWith(services.Keys);
        var hasHistoricalInventory = Catalog is not null || LegacyServices.Count > 0 || previous.Count > 0;
        foreach (var (mode, services) in transaction.MatchedCatalog.RoutesByMode)
            if (SelectionInitializedByMode.GetValueOrDefault(mode) &&
                SelectedServiceIdsByMode.TryGetValue(mode, out var ids))
            {
                foreach (var (newId, oldId) in recovered)
                {
                    var wasSelected = ids.Contains(oldId, StringComparer.OrdinalIgnoreCase);
                    ids.RemoveAll(id => id.Equals(oldId, StringComparison.OrdinalIgnoreCase));
                    if (wasSelected && services.ContainsKey(newId) &&
                        !ids.Contains(newId, StringComparer.OrdinalIgnoreCase)) ids.Add(newId);
                }
                foreach (var newId in ambiguous)
                    foreach (var oldId in renameCandidates[newId])
                        ids.RemoveAll(id => id.Equals(oldId, StringComparison.OrdinalIgnoreCase));
            }
        if (SelectNewServices)
            foreach (var (mode, services) in transaction.MatchedCatalog.RoutesByMode)
                if (SelectionInitializedByMode.GetValueOrDefault(mode) &&
                    SelectedServiceIdsByMode.TryGetValue(mode, out var ids))
                {
                    if (hasHistoricalInventory)
                        foreach (var id in services.Keys)
                            if (!known.Contains(id) && !recovered.ContainsKey(id) && !ambiguous.Contains(id) &&
                                !ids.Contains(id, StringComparer.OrdinalIgnoreCase)) ids.Add(id);
                }
        Catalog = transaction.MatchedCatalog.Catalog;
        MatchedRoutesByMode = transaction.MatchedCatalog.RoutesByMode.ToDictionary(
            pair => pair.Key, pair => pair.Value.ToDictionary(
                service => service.Key, service => service.Value.ToList(), StringComparer.OrdinalIgnoreCase));
        UnassignedRoutesByMode = transaction.MatchedCatalog.UnassignedRoutes.ToDictionary(
            pair => pair.Key, pair => pair.Value.ToList());
        SourceSnapshots = transaction.SourceSnapshots.ToDictionary(pair => pair.Key, pair => pair.Value);
        Evidence = transaction.Enrichment;
        LastDiagnostics = transaction.Diagnostics.Concat(ambiguous.Select(id =>
            new MatchDiagnostics("selection", "ambiguous", $"Selection for {id} could not be recovered unambiguously."))).ToList();
        LastCheckAt = transaction.CompletedAt;
        LastSuccessfulRefreshAt = transaction.CompletedAt;
    }

    private static IEnumerable<string> IdentityTokens(CatalogService service)
    {
        foreach (var domain in service.Domains)
        {
            var normalized = domain.Trim().TrimEnd('.').ToLowerInvariant();
            if (normalized.Length > 0) yield return "domain:" + normalized;
        }
        foreach (var asn in service.Asns)
            if (asn > 0) yield return "asn:" + asn;
    }
}

public sealed record ChangeRecord(DateTimeOffset At, string Reason, int Added, int Removed,
    IReadOnlyList<string> AddedRoutes = null!, IReadOnlyList<string> RemovedRoutes = null!);

internal static class RefreshSourceUrlExtensions
{
    public static List<string> ToStringList(this IPList.Core.Refresh.RefreshSourceUrls urls) =>
        [urls.Metadata.ToString(), urls.Targeted.ToString(), urls.Lite.ToString(), urls.Full.ToString()];
}
