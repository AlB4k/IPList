namespace IPList.Core.Refresh;

public sealed class HttpDataClient(HttpClient client, int maxResponseBytes = 4 * 1024 * 1024,
    TimeSpan? requestTimeout = null)
{
    public int MaxResponseBytes { get; } = maxResponseBytes;
    public TimeSpan RequestTimeout { get; } = requestTimeout ?? TimeSpan.FromSeconds(12);

    public async Task<byte[]> GetLimitedAsync(Uri uri, CancellationToken cancellationToken)
    {
        if (!uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps) throw new InvalidOperationException("HTTPS is required.");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linked.CancelAfter(RequestTimeout);
        try { return await GetCoreAsync(uri, linked.Token).WaitAsync(RequestTimeout, cancellationToken).ConfigureAwait(false); }
        catch (TimeoutException ex)
        {
            linked.Cancel();
            throw new OperationCanceledException("HTTP request deadline exceeded.", ex);
        }
    }

    private async Task<byte[]> GetCoreAsync(Uri uri, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (response.RequestMessage?.RequestUri is { } finalUri && finalUri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Insecure redirect rejected.");
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is { } length && length > MaxResponseBytes)
            throw new InvalidOperationException("HTTP response exceeds 4 MiB limit.");
        await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var count = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0) break;
            if (output.Length + count > MaxResponseBytes) throw new InvalidOperationException("HTTP response exceeds 4 MiB limit.");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }
}
