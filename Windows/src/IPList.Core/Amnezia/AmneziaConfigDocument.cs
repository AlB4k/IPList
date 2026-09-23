using System.Net;
using System.Net.Sockets;
using System.Text;
using IPList.Core.Networking;

namespace IPList.Core.Amnezia;

public sealed class AmneziaConfigDocument
{
    private sealed record Line(string Content, string Ending, int Start)
    {
        public int End => Start + Content.Length + Ending.Length;
        public string Raw => Content + Ending;
    }

    private sealed record Section(string Name, int Start, int End, IReadOnlyList<Line> Lines);
    private sealed record KeyLine(string Name, string Value, string Prefix, string Suffix, string? Comment);

    private static readonly UTF8Encoding Utf8 = new(false, true);
    private readonly string _text;
    private readonly bool _bom;
    private readonly IReadOnlyList<Section> _peers;

    private AmneziaConfigDocument(string text, bool bom, IReadOnlyList<Section> peers)
        => (_text, _bom, _peers) = (text, bom, peers);

    public int PeerCount => _peers.Count;

    public static AmneziaConfigDocument Parse(ReadOnlyMemory<byte> bytes)
    {
        var source = bytes.Span;
        var bom = source.Length >= 3 && source[..3].SequenceEqual(new byte[] { 0xEF, 0xBB, 0xBF });
        string text;
        try { text = Utf8.GetString(source[(bom ? 3 : 0)..]); }
        catch (DecoderFallbackException) { throw new AmneziaConfigError("Конфигурация должна быть UTF-8."); }

        var lines = ReadLines(text);
        var sections = new List<Section>();
        var sectionStart = -1;
        var sectionName = "";
        var firstLine = 0;
        for (var i = 0; i < lines.Count; i++)
        {
            var trimmed = lines[i].Content.Trim();
            if (!trimmed.StartsWith('[') || !trimmed.EndsWith(']')) continue;
            if (sectionStart >= 0)
                sections.Add(new Section(sectionName, sectionStart, lines[i].Start,
                    lines.Skip(firstLine).Take(i - firstLine).ToArray()));
            sectionStart = lines[i].Start;
            sectionName = trimmed[1..^1].Trim();
            firstLine = i;
        }
        if (sectionStart >= 0)
            sections.Add(new Section(sectionName, sectionStart, text.Length, lines.Skip(firstLine).ToArray()));

        var interfaces = sections.Where(s => s.Name.Equals("Interface", StringComparison.OrdinalIgnoreCase)).ToArray();
        var peers = sections.Where(s => s.Name.Equals("Peer", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (interfaces.Length != 1 || peers.Length == 0)
            throw new AmneziaConfigError("Нужны одна секция [Interface] и хотя бы одна [Peer].");
        if (sections.Any(s => !s.Name.Equals("Interface", StringComparison.OrdinalIgnoreCase) &&
                              !s.Name.Equals("Peer", StringComparison.OrdinalIgnoreCase)))
            throw new AmneziaConfigError("Неизвестный тип секции конфигурации.");

        ValidateRequired(interfaces[0], ["PrivateKey", "Address"],
            ["PrivateKey", "Address", "ListenPort", "MTU", "Table"]);
        foreach (var peer in peers)
        {
            ValidateRequired(peer, ["PublicKey"],
                ["PublicKey", "PresharedKey", "Endpoint", "PersistentKeepalive"]);
            ReadAllowed(peer);
        }
        return new AmneziaConfigDocument(text, bom, peers);
    }

    public byte[] Render(int peerIndex, AllowedIPsOperation operation, IEnumerable<IPv4Network> selectedRoutes,
        bool preserveIPv6 = true)
    {
        if ((uint)peerIndex >= (uint)_peers.Count) throw new ArgumentOutOfRangeException(nameof(peerIndex));
        ArgumentNullException.ThrowIfNull(selectedRoutes);
        var selected = RouteSet.Normalize(selectedRoutes);
        if (selected.Count == 0) throw new AmneziaConfigError("Набор маршрутов пуст.");
        var peer = _peers[peerIndex];
        var (oldRoutes, ipv6) = ReadAllowed(peer);
        var routes = operation switch
        {
            AllowedIPsOperation.Add => RouteSet.Normalize(oldRoutes.Concat(selected)),
            AllowedIPsOperation.Replace => selected,
            AllowedIPsOperation.Bypass => RouteSet.Subtract(oldRoutes, selected),
            _ => throw new ArgumentOutOfRangeException(nameof(operation))
        };
        IReadOnlyList<string> ipv6Output = preserveIPv6 ? ipv6 : Array.Empty<string>();
        if (routes.Count == 0 && ipv6Output.Count == 0)
            throw new AmneziaConfigError("После операции AllowedIPs пуст.");

        var newlyCovered = RouteSet.Subtract(routes, oldRoutes);
        foreach (var other in _peers.Where((_, index) => index != peerIndex))
        {
            var (otherRoutes, _) = ReadAllowed(other);
            if (newlyCovered.Any(route => otherRoutes.Any(route.Intersects)))
                throw new AmneziaConfigError("Новые маршруты пересекаются с другим peer.");
        }

        var values = routes.Select(r => r.ToString()).Concat(ipv6Output);
        var allowed = peer.Lines.Select((line, index) => (line, index, key: ParseKey(line.Content)))
            .Where(item => item.key?.Name.Equals("AllowedIPs", StringComparison.OrdinalIgnoreCase) == true)
            .ToArray();
        var newline = peer.Lines.Select(line => line.Ending).FirstOrDefault(ending => ending.Length > 0) ?? "\n";
        var output = new StringBuilder();
        var insertion = peer.Lines.Select((line, index) => (line, index, key: ParseKey(line.Content)))
            .First(item => item.key?.Name.Equals("PublicKey", StringComparison.OrdinalIgnoreCase) == true).index;
        for (var i = 0; i < peer.Lines.Count; i++)
        {
            var line = peer.Lines[i];
            if (allowed.Length > 0 && i == allowed[0].index)
            {
                var key = allowed[0].key!;
                output.Append(key.Prefix).Append(string.Join(", ", values)).Append(key.Suffix);
                if (key.Comment is not null) output.Append(key.Comment);
                output.Append(line.Ending);
            }
            else if (allowed.Any(item => item.index == i))
            {
                var comment = ParseKey(line.Content)?.Comment;
                if (comment is not null)
                    output.Append(line.Content[..(line.Content.Length - line.Content.TrimStart().Length)])
                        .Append(comment).Append(line.Ending);
            }
            else output.Append(line.Raw);

            if (allowed.Length == 0 && i == insertion)
            {
                if (line.Ending.Length == 0) output.Append(newline);
                output.Append("AllowedIPs = ").Append(string.Join(", ", values));
                if (i < peer.Lines.Count - 1 || line.Ending.Length > 0) output.Append(newline);
            }
        }
        var result = _text[..peer.Start] + output + _text[peer.End..];
        var data = Utf8.GetBytes(result);
        return _bom ? new byte[] { 0xEF, 0xBB, 0xBF }.Concat(data).ToArray() : data;
    }

    private static List<Line> ReadLines(string text)
    {
        var lines = new List<Line>();
        for (var start = 0; start < text.Length;)
        {
            var end = text.IndexOf('\n', start);
            if (end < 0) { lines.Add(new Line(text[start..], "", start)); break; }
            var crlf = end > start && text[end - 1] == '\r';
            lines.Add(new Line(text[start..(crlf ? end - 1 : end)], crlf ? "\r\n" : "\n", start));
            start = end + 1;
        }
        return lines;
    }

    private static KeyLine? ParseKey(string line)
    {
        var trimmed = line.TrimStart();
        if (trimmed.Length == 0 || trimmed[0] is '#' or ';' or '[') return null;
        var equal = line.IndexOf('=');
        if (equal < 0) return null;
        var key = line[..equal].Trim();
        if (key.Length == 0 || key.Any(c => !char.IsLetterOrDigit(c))) return null;
        var valueStart = equal + 1;
        while (valueStart < line.Length && char.IsWhiteSpace(line[valueStart])) valueStart++;
        var value = line[valueStart..];
        var commentAt = value.IndexOfAny(['#', ';']);
        var comment = commentAt >= 0 ? value[commentAt..] : null;
        if (commentAt >= 0) value = value[..commentAt];
        var suffix = value[value.TrimEnd().Length..];
        return new KeyLine(key, value.Trim(), line[..valueStart], suffix, comment);
    }

    private static void ValidateRequired(Section section, IReadOnlyList<string> required,
        IReadOnlyList<string> singleton)
    {
        var keys = section.Lines.Select(line => ParseKey(line.Content)).Where(key => key is not null).ToArray();
        foreach (var name in required)
            if (keys.Count(key => key!.Name.Equals(name, StringComparison.OrdinalIgnoreCase) &&
                                  key.Value.Length > 0) != 1)
                throw new AmneziaConfigError($"Отсутствует обязательный ключ {name}.");
        foreach (var name in singleton)
            if (keys.Count(key => key!.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) > 1)
                throw new AmneziaConfigError($"Повторяется ключ {name}.");
    }

    private static (IReadOnlyList<IPv4Network> IPv4, IReadOnlyList<string> IPv6) ReadAllowed(Section peer)
    {
        var ipv4 = new List<IPv4Network>();
        var ipv6 = new List<string>();
        foreach (var key in peer.Lines.Select(line => ParseKey(line.Content)))
        {
            if (key?.Name.Equals("AllowedIPs", StringComparison.OrdinalIgnoreCase) != true) continue;
            foreach (var token in key.Value.Split(',', StringSplitOptions.TrimEntries))
            {
                if (token.Length == 0) throw new AmneziaConfigError("Пустой маршрут в AllowedIPs.");
                if (IPv4Network.TryParse(token, out var route)) { ipv4.Add(route); continue; }
                var parts = token.Split('/');
                if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var address) ||
                    address.AddressFamily != AddressFamily.InterNetworkV6 ||
                    !int.TryParse(parts[1], out var prefix) || prefix is < 0 or > 128)
                    throw new AmneziaConfigError("Некорректный CIDR в AllowedIPs.");
                if (!ipv6.Contains(token, StringComparer.OrdinalIgnoreCase)) ipv6.Add(token);
            }
        }
        return (RouteSet.Normalize(ipv4), ipv6);
    }
}
