using System.Text.Json;

namespace IPList.Core.State;

public sealed record StateLoadResult(AppState State, bool Migrated, string? BackupPath);

public sealed class StateStore
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    public async Task<StateLoadResult> LoadAsync(string path, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return new(new AppState(), false, null);
        var bytes = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        var state = JsonSerializer.Deserialize<AppState>(bytes, Options) ?? new AppState();
        return new(state, state.SchemaVersion < 1, null);
    }

    public Task SaveAsync(AppState state, string path, CancellationToken cancellationToken = default) =>
        AtomicFile.WriteAsync(path, JsonSerializer.SerializeToUtf8Bytes(state, Options), cancellationToken);
}

internal static class AtomicFile
{
    public static async Task WriteAsync(string path, byte[] bytes, CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(path) ?? throw new ArgumentException("Path must have a directory", nameof(path));
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        await File.WriteAllBytesAsync(temporary, bytes, cancellationToken).ConfigureAwait(false);
        File.Move(temporary, path, true);
    }
}
