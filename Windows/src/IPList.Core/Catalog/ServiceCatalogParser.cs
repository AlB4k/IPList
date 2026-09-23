using System.Text;
using IPList.Core.Networking;

namespace IPList.Core.Catalog;

public sealed record ServiceCatalogLimits(int MaxInputBytes = 4 * 1024 * 1024,
    int MaxServices = 2_000, int MaxDomains = 20_000, int MaxRanges = 20_000,
    int MaxAsns = 20_000, int MaxFieldBytes = 512);

public static class ServiceCatalogParser
{
    private sealed class Builder(int line, string category)
    {
        public int Line { get; } = line;
        public string Category { get; } = category;
        public string? Name { get; set; }
        public List<string> Domains { get; } = [];
        public List<long> Asns { get; } = [];
        public List<IPv4Network> Ranges { get; } = [];
    }

    public static ServiceCatalog Parse(ReadOnlySpan<byte> bytes, ServiceCatalogLimits? limits = null)
    {
        limits ??= new ServiceCatalogLimits();
        if (bytes.Length > limits.MaxInputBytes) throw new FormatException("Catalog exceeds 4 MiB limit.");
        string yaml;
        try { yaml = new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException ex) { throw new FormatException("Catalog is not UTF-8.", ex); }
        var services = new List<CatalogService>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        Builder? current = null;
        string? list = null;
        int listIndent = 0, serviceIndent = -1, domains = 0, ranges = 0, asns = 0;
        var category = "Без категории";
        var dividerOpened = false;
        var closingDividerExpected = false;
        string? categoryCandidate = null;
        var inServices = false;
        var lines = yaml.Split('\n');

        void CloseList(int lineNumber)
        {
            if (list is null || current is null) { list = null; return; }
            var count = list switch { "domains" => current.Domains.Count, "asn" => current.Asns.Count, _ => current.Ranges.Count };
            if (count == 0) throw new FormatException($"Empty {list} list at line {lineNumber}.");
            list = null;
        }

        void Finish(Builder b)
        {
            var name = b.Name?.Trim();
            if (string.IsNullOrEmpty(name)) throw new FormatException($"Service name missing at line {b.Line}.");
            CheckField(name, limits.MaxFieldBytes);
            CheckField(b.Category, limits.MaxFieldBytes);
            if (b.Domains.Count + b.Asns.Count + b.Ranges.Count == 0) throw new FormatException("Service has no metadata.");
            var id = CatalogService.StableId(name);
            if (!ids.Add(id)) throw new FormatException("Duplicate service ID.");
            services.Add(new CatalogService(id, name, b.Category, b.Domains, b.Asns, b.Ranges));
            if (services.Count > limits.MaxServices) throw new FormatException("Too many catalog services.");
        }

        void Add(string field, string raw, int lineNumber)
        {
            if (current is null) return;
            var scalar = Scalar(raw);
            if (scalar is null || scalar.Length == 0) throw new FormatException($"Empty catalog value at line {lineNumber}.");
            CheckField(scalar, limits.MaxFieldBytes);
            switch (field)
            {
                case "domains":
                    var domain = scalar.Trim().Trim('.').ToLowerInvariant();
                    if (domain.Length == 0 || domain.Any(char.IsWhiteSpace)) throw new FormatException("Invalid domain.");
                    if (!current.Domains.Contains(domain)) { current.Domains.Add(domain); if (++domains > limits.MaxDomains) throw new FormatException("Too many domains."); }
                    break;
                case "asn":
                    if (!long.TryParse(scalar, out var number) || number is < 1 or > uint.MaxValue) throw new FormatException("Invalid ASN.");
                    if (!current.Asns.Contains(number)) { current.Asns.Add(number); if (++asns > limits.MaxAsns) throw new FormatException("Too many ASNs."); }
                    break;
                case "ip_ranges":
                    if (!IPv4Network.TryParse(scalar, out var network)) throw new FormatException("Invalid IPv4 range.");
                    if (!current.Ranges.Contains(network)) { current.Ranges.Add(network); if (++ranges > limits.MaxRanges) throw new FormatException("Too many IPv4 ranges."); }
                    break;
            }
        }

        for (var i = 0; i < lines.Length; i++)
        {
            var raw = lines[i].TrimEnd('\r');
            var indent = raw.Length - raw.TrimStart(' ', '\t').Length;
            var trimmed = raw.Trim();
            if (trimmed.Length == 0) continue;
            if (inServices && trimmed.StartsWith('#') && (serviceIndent < 0 || indent <= serviceIndent))
            {
                var comment = trimmed[1..].Trim();
                if (IsDivider(comment))
                {
                    if (closingDividerExpected && categoryCandidate is not null)
                    {
                        category = categoryCandidate; categoryCandidate = null; closingDividerExpected = false; dividerOpened = false;
                    }
                    else { category = "Без категории"; categoryCandidate = null; closingDividerExpected = false; dividerOpened = true; }
                }
                else if (dividerOpened && IsHeading(comment))
                {
                    var collapsed = string.Join(' ', comment.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
                    var normalized = collapsed == collapsed.ToUpperInvariant() ? collapsed.ToLowerInvariant() : collapsed;
                    categoryCandidate = char.ToUpperInvariant(normalized[0]) + normalized[1..];
                    dividerOpened = false; closingDividerExpected = true;
                }
                else { category = "Без категории"; categoryCandidate = null; dividerOpened = closingDividerExpected = false; }
                CloseList(i + 1);
                continue;
            }
            var body = StripComment(raw).Trim();
            if (body.Length == 0) continue;
            if (indent == 0 && body == "services:") { inServices = true; list = null; continue; }
            if (!inServices) continue;
            if (body == "-" || body.StartsWith("- ", StringComparison.Ordinal))
            {
                if (serviceIndent >= 0 && indent > serviceIndent)
                {
                    if (list is not null && indent > listIndent) Add(list, body[1..].Trim(), i + 1);
                    continue;
                }
                CloseList(i + 1);
                if (current is not null) Finish(current);
                if (serviceIndent >= 0 && indent != serviceIndent) throw new FormatException("Inconsistent service indentation.");
                serviceIndent = indent;
                current = new Builder(i + 1, category);
                var rest = body[1..].Trim();
                if (Pair(rest) is { } first && first.Key == "name") current.Name = Scalar(first.Value);
                continue;
            }
            if (current is null) continue;
            if (indent > serviceIndent + 2) { CloseList(i + 1); continue; }
            CloseList(i + 1);
            if (Pair(body) is not { } pair) continue;
            switch (pair.Key)
            {
                case "name": current.Name = Scalar(pair.Value); break;
                case "domains": case "asn": case "ip_ranges":
                    if (pair.Value.Length == 0) { list = pair.Key; listIndent = indent; }
                    else
                    {
                        if (!pair.Value.StartsWith('[') || !pair.Value.EndsWith(']')) throw new FormatException("Known catalog list must be an array.");
                        foreach (var value in SplitArray(pair.Value[1..^1])) Add(pair.Key, value, i + 1);
                    }
                    break;
            }
        }
        CloseList(lines.Length);
        if (current is not null) Finish(current);
        if (services.Count == 0) throw new FormatException("Catalog is empty.");
        return new ServiceCatalog(services);
    }

    private static void CheckField(string text, int limit)
    {
        if (Encoding.UTF8.GetByteCount(text) > limit) throw new FormatException("Catalog field exceeds byte limit.");
    }

    private static (string Key, string Value)? Pair(string text)
    {
        var colon = text.IndexOf(':');
        return colon <= 0 ? null : (text[..colon].Trim(), text[(colon + 1)..].Trim());
    }

    private static string? Scalar(string raw)
    {
        var value = raw.Trim();
        if (value.Length == 0 || value is "null" or "~") return null;
        if (value.Length >= 2 && value[0] == '"' && value[^1] == '"')
            return value[1..^1].Replace("\\\"", "\"").Replace("\\n", "\n").Replace("\\t", "\t").Replace("\\\\", "\\");
        if (value.Length >= 2 && value[0] == '\'' && value[^1] == '\'') return value[1..^1].Replace("''", "'");
        return value;
    }

    private static IEnumerable<string> SplitArray(string input)
    {
        if (input.Trim().Length == 0) return [];
        var values = new List<string>();
        var current = new StringBuilder();
        char quote = '\0';
        var escaped = false;
        foreach (var c in input)
        {
            if (escaped) { current.Append(c); escaped = false; continue; }
            if (c == '\\' && quote == '"') { current.Append(c); escaped = true; continue; }
            if (quote != '\0') { current.Append(c); if (c == quote) quote = '\0'; }
            else if (c is '"' or '\'') { quote = c; current.Append(c); }
            else if (c == ',') { values.Add(current.ToString()); current.Clear(); }
            else current.Append(c);
        }
        if (quote != '\0') throw new FormatException("Unclosed YAML quote.");
        values.Add(current.ToString());
        if (values.Any(x => Scalar(x) is null)) throw new FormatException("Empty YAML array value.");
        return values;
    }

    private static string StripComment(string text)
    {
        char quote = '\0';
        var escaped = false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (escaped) { escaped = false; continue; }
            if (c == '\\' && quote == '"') { escaped = true; continue; }
            if (quote != '\0') { if (c == quote) quote = '\0'; }
            else if (c is '"' or '\'') quote = c;
            else if (c == '#') return text[..i];
        }
        return text;
    }

    private static bool IsDivider(string text) => text.Length > 0 && text.All(c => c is '=' or '-' or '_');
    private static bool IsHeading(string text) => text.Length > 0 && text == text.ToUpperInvariant() && !text.Contains(':') && text.Any(char.IsLetter);
}
