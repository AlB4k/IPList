namespace IPList.Core.Amnezia;

public static class BatchOutputNamer
{
    public static IReadOnlyList<string> Create(IEnumerable<string> inputPaths, string outputDirectory)
    {
        Directory.CreateDirectory(outputDirectory);
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        foreach (var input in inputPaths)
        {
            var stem = Path.GetFileNameWithoutExtension(input);
            var candidate = Path.Combine(outputDirectory, stem + "-iplist.conf");
            var n = 2;
            while (!used.Add(candidate)) candidate = Path.Combine(outputDirectory, $"{stem}-iplist-{n++}.conf");
            result.Add(candidate);
        }
        return result;
    }
}
