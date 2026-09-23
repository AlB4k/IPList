using System.Text;
using IPList.Core.Networking;

namespace IPList.Core.Amnezia;

public sealed class AmneziaConfigDocument
{
    private readonly byte[] _source;
    private readonly Encoding _encoding;
    private readonly string _text;
    private readonly List<(int Start, int End)> _peers;

    private AmneziaConfigDocument(byte[] source, Encoding encoding, string text, List<(int, int)> peers)
        => (_source, _encoding, _text, _peers) = (source, encoding, text, peers);

    public int PeerCount => _peers.Count;

    public static AmneziaConfigDocument Parse(ReadOnlyMemory<byte> bytes)
    {
        var source = bytes.ToArray();
        var hasBom = source.Length >= 3 && source[0] == 0xEF && source[1] == 0xBB && source[2] == 0xBF;
        var encoding = new UTF8Encoding(false, true);
        var text = encoding.GetString(source, hasBom ? 3 : 0, source.Length - (hasBom ? 3 : 0));
        var lines = text.Split('\n');
        var peers = new List<(int, int)>();
        var offset = 0; var start = -1;
        for (var i = 0; i < lines.Length; i++)
        {
            if (lines[i].Trim().Equals("[Peer]", StringComparison.OrdinalIgnoreCase))
            {
                if (start >= 0) peers.Add((start, offset));
                start = offset;
            }
            offset += lines[i].Length + 1;
        }
        if (start >= 0) peers.Add((start, text.Length));
        if (peers.Count == 0) throw new AmneziaConfigError("Конфигурация не содержит секцию [Peer].");
        return new(source, encoding, text, peers);
    }

    public byte[] Render(int peerIndex, AllowedIPsOperation operation, IEnumerable<IPv4Network> selectedRoutes, bool preserveIPv6 = true)
    {
        if ((uint)peerIndex >= (uint)_peers.Count) throw new ArgumentOutOfRangeException(nameof(peerIndex));
        var selected = RouteSet.Normalize(selectedRoutes).ToHashSet();
        if (selected.Count == 0) throw new AmneziaConfigError("Набор маршрутов пуст.");
        var (start, end) = _peers[peerIndex];
        var section = _text[start..end];
        var lines = section.Split('\n').ToList();
        var indices = lines.Select((line, i) => (line, i)).Where(x => x.line.TrimStart().StartsWith("AllowedIPs", StringComparison.OrdinalIgnoreCase)).Select(x => x.i).ToList();
        var existing = new List<IPv4Network>();
        foreach (var index in indices)
        {
            var value = lines[index].Split('=', 2).ElementAtOrDefault(1) ?? "";
            foreach (var token in value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                if (token.Contains(':')) { if (!preserveIPv6) continue; }
                else if (IPv4Network.TryParse(token, out var route)) existing.Add(route);
                else throw new AmneziaConfigError("Некорректный IPv4 маршрут в AllowedIPs.");
        }
        var output = operation switch
        {
            AllowedIPsOperation.Replace => selected,
            AllowedIPsOperation.Add => RouteSet.Normalize(existing.Concat(selected)).ToHashSet(),
            AllowedIPsOperation.Bypass => RouteSet.Normalize(existing.SelectMany(x => SubtractAll(x, selected))).ToHashSet(),
            _ => selected
        };
        if (output.Count == 0) throw new AmneziaConfigError("После операции AllowedIPs пуст.");
        var line = "AllowedIPs = " + string.Join(", ", output.OrderBy(x => x).Select(x => x.ToString()));
        if (indices.Count > 0) lines[indices[0]] = line;
        else
        {
            var key = lines.FindIndex(x => x.TrimStart().StartsWith("PublicKey", StringComparison.OrdinalIgnoreCase));
            if (key < 0) throw new AmneziaConfigError("В peer отсутствует PublicKey.");
            lines.Insert(key + 1, line);
        }
        var renderedSection = string.Join('\n', lines);
        var resultText = _text[..start] + renderedSection + _text[end..];
        var bom = _source.Length >= 3 && _source[0] == 0xEF && _source[1] == 0xBB && _source[2] == 0xBF ? "\uFEFF" : "";
        return _encoding.GetBytes(bom + resultText);
    }

    private static IEnumerable<IPv4Network> SubtractAll(IPv4Network source, IEnumerable<IPv4Network> removals)
    {
        IEnumerable<IPv4Network> current = [source];
        foreach (var removal in removals)
            current = current.SelectMany(route => route.Intersects(removal) ? route.Subtract(removal) : [route]);
        return current;
    }
}
