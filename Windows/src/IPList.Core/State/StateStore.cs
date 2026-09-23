using System.Text.Json;
using System.Text.Json.Serialization;
using IPList.Core.Networking;

namespace IPList.Core.State;

public sealed record StateLoadResult(AppState State, bool Migrated, string? BackupPath);

public sealed class StateStore
{
    private static readonly JsonSerializerOptions Options = CreateOptions();
    public async Task<StateLoadResult> LoadAsync(string path, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return new(new AppState(), false, null);
        var bytes = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        using var document = JsonDocument.Parse(bytes);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new JsonException("Invalid state document.");
        var version = document.RootElement.TryGetProperty("schemaVersion", out var schema)
            ? schema.ValueKind == JsonValueKind.Number && schema.TryGetInt32(out var number)
                ? number : throw new JsonException("Invalid state schema version.")
            : 0;
        if (version is < 0 or > 1) throw new JsonException("Unsupported state schema version.");
        string? backup = null;
        if (version == 0)
        {
            backup = Path.Combine(Path.GetDirectoryName(path)!, "state-before-v1.4.json");
            if (!File.Exists(backup)) await AtomicFile.WriteNewAsync(backup, bytes, cancellationToken).ConfigureAwait(false);
        }
        var state = JsonSerializer.Deserialize<AppState>(bytes, Options) ?? throw new JsonException("Invalid state document.");
        state.SchemaVersion = 1;
        if (version == 0 && state.History is { Count: > 100 })
            state.History.RemoveRange(100, state.History.Count - 100);
        Validate(state);
        return new(state, version == 0, backup);
    }

    public Task SaveAsync(AppState state, string path, CancellationToken cancellationToken = default)
    {
        Validate(state);
        return AtomicFile.WriteAsync(path, JsonSerializer.SerializeToUtf8Bytes(state, Options), cancellationToken);
    }

    public async Task SaveAsync(AppState state, string path, byte[] rawLegacyBytes, CancellationToken cancellationToken = default)
    {
        Validate(state);
        ArgumentNullException.ThrowIfNull(rawLegacyBytes);
        var backup = Path.Combine(Path.GetDirectoryName(path)!, "state-before-v1.4.json");
        if (!File.Exists(backup)) await AtomicFile.WriteNewAsync(backup, rawLegacyBytes, cancellationToken).ConfigureAwait(false);
        await SaveAsync(state, path, cancellationToken).ConfigureAwait(false);
    }

    private static void Validate(AppState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (state.SchemaVersion != 1 || state.IntervalHours is < 1 or > 720 ||
            !Enum.IsDefined(state.Mode) || state.ManualRoutes is null || state.Profiles is null ||
            state.SelectedServiceIds is null || state.SelectedRemainders is null ||
            state.SelectedServiceIdsByMode is null || state.RemaindersSelectedByMode is null ||
            state.SelectionInitializedByMode is null || state.LegacyServices is null ||
            state.MatchedRoutesByMode is null || state.UnassignedRoutesByMode is null ||
            state.SourceSnapshots is null || state.LastDiagnostics is null ||
            state.MigrationDiagnostics is null ||
            state.SourceUrls is null || state.SourceUrls.Count != 4 ||
            state.History is null || state.History.Count > 100)
            throw new JsonException("Invalid state schema.");
        foreach (var url in state.SourceUrls)
            if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed) || parsed.Scheme != Uri.UriSchemeHttps)
                throw new JsonException("Invalid source URL in state.");
        foreach (var route in state.ManualRoutes)
            if (route is null || !IPv4Network.TryParse(route.Value, out _))
                throw new JsonException("Invalid manual route in state.");
    }

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true };
        options.Converters.Add(new IPv4NetworkConverter());
        return options;
    }
}

internal sealed class IPv4NetworkConverter : JsonConverter<IPv4Network>
{
    public override IPv4Network Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String && IPv4Network.TryParse(reader.GetString(), out var route)
            ? route : throw new JsonException("Invalid saved IPv4 route.");

    public override void Write(Utf8JsonWriter writer, IPv4Network value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
}

internal static class AtomicFile
{
    public static async Task WriteAsync(string path, byte[] bytes, CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(path) ?? throw new ArgumentException("Path must have a directory", nameof(path));
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(true);
            }
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { /* Keep the write error. */ } }
    }

    public static async Task WriteNewAsync(string path, byte[] bytes, CancellationToken cancellationToken)
    {
        if (File.Exists(path)) return;
        var directory = Path.GetDirectoryName(path) ?? throw new ArgumentException("Path must have a directory", nameof(path));
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(true);
            }
            File.Move(temporary, path);
        }
        catch (IOException) when (File.Exists(path)) { }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { /* Keep the write error. */ } }
    }
}
