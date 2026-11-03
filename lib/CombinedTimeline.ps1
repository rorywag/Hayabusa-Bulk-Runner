# The combined timeline, OutputRoot\combined_timeline.csv. Every included
# host's Hayabusa timeline merged into one file in time order, with the
# same columns and each row copied byte for byte as Hayabusa wrote it, so
# it opens anywhere a single Hayabusa timeline does.

$script:CombinedTimelineName = 'combined_timeline.csv'

# Hayabusa run with -U and no other time format flag writes every Timestamp
# as UTC in this one form, for example 2026-10-01 10:00:00.000 +00:00.
$script:CombinedTimestampForm = 'yyyy-MM-dd HH:mm:ss.fff +00:00'

# Read and write buffers, the longest row taken, and how many distinct
# computer names per host are kept for the shared name check. A row longer
# than the limit is refused, so a quote that never closes can't pull the
# rest of a file into memory.
$script:CombinedBufferBytes = 1MB
$script:CombinedMaxRecordBytes = 64MB
$script:CombinedMaxComputers = 4096

# The merge, compiled once the first time a combined timeline is built. A
# PowerShell loop per row would take minutes on a large run, so the byte
# scanning and the k-way merge are done here. Each record's raw bytes are
# found by tracking quotes, so commas and line breaks inside a quoted field
# stay part of it, and are written out unchanged. Only the Timestamp and
# Computer fields are decoded, for ordering and the shared name check.
$script:CombinedTimelineSource = @'
namespace HayabusaBulkRunner
{
    using System;
    using System.Collections.Generic;
    using System.Globalization;
    using System.IO;
    using System.Text;

    public sealed class TimelineMergeException : Exception
    {
        private readonly int input;
        private readonly long line;
        private readonly string kind;

        public TimelineMergeException(int input, long line, string kind, string message) : base(message)
        {
            this.input = input;
            this.line = line;
            this.kind = kind;
        }

        public int Input { get { return input; } }
        public long Line { get { return line; } }
        public string Kind { get { return kind; } }
    }

    public sealed class TimelineHeader
    {
        public bool Empty;
        public bool Bom;
        public string[] Columns;
    }

    public sealed class TimelineMergeResult
    {
        public long Rows;
        public long[] RowsPerInput;
        public long PeakHeldBytes;
        public string[][] Computers;
        public bool[] ComputersCapped;
    }

    internal sealed class TimelineRecordReader : IDisposable
    {
        private readonly FileStream stream;
        private readonly byte[] buffer;
        private readonly int input;
        private readonly int maxRecordBytes;
        private int length;
        private int position;
        private bool atEnd;
        private long nextLine = 1;
        private byte[] record = new byte[4096];

        public int RecordLength;
        public long RecordLine;
        public bool HasTerminator;
        public bool Bom;

        public TimelineRecordReader(string path, int input, int bufferBytes, int maxRecordBytes)
        {
            this.input = input;
            this.maxRecordBytes = maxRecordBytes;
            buffer = new byte[bufferBytes];
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan);
            ReadBom();
        }

        public byte[] Record { get { return record; } }

        public long HeldBytes { get { return buffer.Length + record.Length; } }

        private bool Fill()
        {
            if (atEnd)
            {
                return false;
            }
            length = stream.Read(buffer, 0, buffer.Length);
            position = 0;
            if (length == 0)
            {
                atEnd = true;
                return false;
            }
            return true;
        }

        private void ReadBom()
        {
            // A short read is possible, so the first three bytes are read
            // one at a time until they're in or the file ends.
            if (!Fill())
            {
                return;
            }
            while (length < 3)
            {
                int n = stream.Read(buffer, length, buffer.Length - length);
                if (n == 0)
                {
                    break;
                }
                length += n;
            }
            if (length >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF)
            {
                Bom = true;
                position = 3;
            }
        }

        private void Append(int start, int count)
        {
            if (count == 0)
            {
                return;
            }
            long needed = (long)RecordLength + count;
            if (needed > maxRecordBytes)
            {
                throw new TimelineMergeException(input, RecordLine, "TooLong", "A row is longer than the limit.");
            }
            if (needed > record.Length)
            {
                long size = record.Length;
                while (size < needed)
                {
                    size *= 2;
                }
                byte[] grown = new byte[(int)Math.Min(size, (long)maxRecordBytes)];
                Buffer.BlockCopy(record, 0, grown, 0, RecordLength);
                record = grown;
            }
            Buffer.BlockCopy(buffer, start, record, RecordLength, count);
            RecordLength += count;
        }

        // The next record's raw bytes, its line ending included, or false at
        // the end of the file. A line ending inside quotes is part of the
        // record. A doubled quote toggles twice, so it never ends a field.
        public bool Next()
        {
            RecordLength = 0;
            RecordLine = nextLine;
            HasTerminator = false;
            bool inQuotes = false;
            while (true)
            {
                if (position >= length && !Fill())
                {
                    if (inQuotes)
                    {
                        throw new TimelineMergeException(input, RecordLine, "Unterminated", "A quoted field never closes.");
                    }
                    return RecordLength > 0;
                }
                int start = position;
                while (position < length)
                {
                    byte b = buffer[position++];
                    if (b == 0x22)
                    {
                        inQuotes = !inQuotes;
                    }
                    else if (b == 0x0A)
                    {
                        nextLine++;
                        if (!inQuotes)
                        {
                            Append(start, position - start);
                            HasTerminator = true;
                            return true;
                        }
                    }
                }
                Append(start, position - start);
            }
        }

        // Like Next, but passes over blank lines.
        public bool NextNonBlank()
        {
            while (Next())
            {
                int end = ContentEnd(record, RecordLength);
                if (end > 0)
                {
                    return true;
                }
            }
            return false;
        }

        public void Dispose()
        {
            stream.Dispose();
        }

        internal static int ContentEnd(byte[] data, int count)
        {
            int end = count;
            if (end > 0 && data[end - 1] == 0x0A)
            {
                end--;
                if (end > 0 && data[end - 1] == 0x0D)
                {
                    end--;
                }
            }
            return end;
        }
    }

    public static class CombinedTimeline
    {
        private static readonly UTF8Encoding Lenient = new UTF8Encoding(false, false);
        private const string Template = "dddd-dd-dd dd:dd:dd.ddd +00:00";

        // One field of a record, unquoted, or null when the record has fewer
        // fields than that.
        internal static string GetField(byte[] data, int count, int index)
        {
            int end = TimelineRecordReader.ContentEnd(data, count);
            int field = 0;
            int i = 0;
            while (true)
            {
                if (field == index)
                {
                    return ReadField(data, i, end);
                }
                if (i < end && data[i] == 0x22)
                {
                    i++;
                    while (i < end)
                    {
                        if (data[i] == 0x22)
                        {
                            if (i + 1 < end && data[i + 1] == 0x22)
                            {
                                i += 2;
                                continue;
                            }
                            i++;
                            break;
                        }
                        i++;
                    }
                }
                while (i < end && data[i] != 0x2C)
                {
                    i++;
                }
                if (i >= end)
                {
                    return null;
                }
                i++;
                field++;
            }
        }

        private static string ReadField(byte[] data, int i, int end)
        {
            if (i < end && data[i] == 0x22)
            {
                List<byte> value = new List<byte>();
                i++;
                while (i < end)
                {
                    if (data[i] == 0x22)
                    {
                        if (i + 1 < end && data[i + 1] == 0x22)
                        {
                            value.Add(0x22);
                            i += 2;
                            continue;
                        }
                        break;
                    }
                    value.Add(data[i]);
                    i++;
                }
                return Lenient.GetString(value.ToArray());
            }
            int start = i;
            while (i < end && data[i] != 0x2C)
            {
                i++;
            }
            return Lenient.GetString(data, start, i - start);
        }

        internal static string[] GetFields(byte[] data, int count)
        {
            List<string> fields = new List<string>();
            int index = 0;
            while (true)
            {
                string value = GetField(data, count, index);
                if (value == null)
                {
                    break;
                }
                fields.Add(value);
                index++;
            }
            return fields.ToArray();
        }

        // True, with the time in ticks, when the value is in Hayabusa's UTC
        // form and is a real date and time.
        public static bool TryParseTimestamp(string value, out long ticks)
        {
            ticks = 0;
            if (value == null || value.Length != Template.Length)
            {
                return false;
            }
            for (int i = 0; i < Template.Length; i++)
            {
                char want = Template[i];
                char got = value[i];
                if (want == 'd')
                {
                    if (got < '0' || got > '9')
                    {
                        return false;
                    }
                }
                else if (want != got)
                {
                    return false;
                }
            }
            DateTime parsed;
            if (!DateTime.TryParseExact(value.Substring(0, 23), "yyyy'-'MM'-'dd' 'HH':'mm':'ss'.'fff", CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed))
            {
                return false;
            }
            ticks = parsed.Ticks;
            return true;
        }

        public static TimelineHeader ReadHeader(string path, int bufferBytes, int maxRecordBytes)
        {
            TimelineHeader header = new TimelineHeader();
            using (TimelineRecordReader reader = new TimelineRecordReader(path, 0, bufferBytes, maxRecordBytes))
            {
                header.Bom = reader.Bom;
                if (!reader.NextNonBlank())
                {
                    header.Empty = true;
                    header.Columns = new string[0];
                    return header;
                }
                header.Columns = GetFields(reader.Record, reader.RecordLength);
            }
            return header;
        }

        private static bool Before(long[] ticks, int a, int b)
        {
            if (ticks[a] != ticks[b])
            {
                return ticks[a] < ticks[b];
            }
            return a < b;
        }

        private static void SiftUp(int[] heap, int at, long[] ticks)
        {
            while (at > 0)
            {
                int parent = (at - 1) / 2;
                if (!Before(ticks, heap[at], heap[parent]))
                {
                    break;
                }
                int t = heap[at];
                heap[at] = heap[parent];
                heap[parent] = t;
                at = parent;
            }
        }

        private static void SiftDown(int[] heap, int count, long[] ticks)
        {
            int at = 0;
            while (true)
            {
                int left = at * 2 + 1;
                if (left >= count)
                {
                    break;
                }
                int best = left;
                int right = left + 1;
                if (right < count && Before(ticks, heap[right], heap[left]))
                {
                    best = right;
                }
                if (!Before(ticks, heap[best], heap[at]))
                {
                    break;
                }
                int t = heap[at];
                heap[at] = heap[best];
                heap[best] = t;
                at = best;
            }
        }

        // Reads the next data row of one input into place, checking its
        // Timestamp and that it isn't earlier than the row before it.
        private static bool Advance(TimelineRecordReader reader, int input, int timestampIndex, long[] ticks, bool first)
        {
            if (!reader.NextNonBlank())
            {
                return false;
            }
            string value = GetField(reader.Record, reader.RecordLength, timestampIndex);
            long t;
            if (!TryParseTimestamp(value, out t))
            {
                throw new TimelineMergeException(input, reader.RecordLine, "Timestamp", "A Timestamp isn't in the expected form.");
            }
            if (!first && t < ticks[input])
            {
                throw new TimelineMergeException(input, reader.RecordLine, "Order", "A row is earlier than the one before it.");
            }
            ticks[input] = t;
            return true;
        }

        // Merges the inputs into a new file at outputPath, which must not
        // exist. Every input must already have the same header, checked by
        // the caller. An empty input adds nothing. Rows with the same
        // Timestamp keep the inputs' order, then their order in the file.
        public static TimelineMergeResult Merge(string[] paths, string outputPath, int timestampIndex, int computerIndex, int maxComputers, int bufferBytes, int maxRecordBytes)
        {
            int k = paths.Length;
            TimelineRecordReader[] readers = new TimelineRecordReader[k];
            long[] ticks = new long[k];
            int[] heap = new int[k];
            int heapCount = 0;
            TimelineMergeResult result = new TimelineMergeResult();
            result.RowsPerInput = new long[k];
            result.Computers = new string[k][];
            result.ComputersCapped = new bool[k];
            Dictionary<string, bool>[] seen = new Dictionary<string, bool>[k];
            List<string>[] names = new List<string>[k];
            byte[][] lineEndings = new byte[k][];
            try
            {
                using (FileStream output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, bufferBytes))
                {
                    bool headerWritten = false;
                    for (int i = 0; i < k; i++)
                    {
                        seen[i] = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
                        names[i] = new List<string>();
                        readers[i] = new TimelineRecordReader(paths[i], i, bufferBytes, maxRecordBytes);
                        TimelineRecordReader r = readers[i];
                        if (!r.NextNonBlank())
                        {
                            continue;
                        }
                        int end = TimelineRecordReader.ContentEnd(r.Record, r.RecordLength);
                        lineEndings[i] = new byte[r.RecordLength - end];
                        Buffer.BlockCopy(r.Record, end, lineEndings[i], 0, lineEndings[i].Length);
                        if (lineEndings[i].Length == 0)
                        {
                            lineEndings[i] = new byte[] { 0x0A };
                        }
                        if (!headerWritten)
                        {
                            if (r.Bom)
                            {
                                output.Write(new byte[] { 0xEF, 0xBB, 0xBF }, 0, 3);
                            }
                            output.Write(r.Record, 0, r.RecordLength);
                            if (!r.HasTerminator)
                            {
                                output.Write(lineEndings[i], 0, lineEndings[i].Length);
                            }
                            headerWritten = true;
                        }
                        if (Advance(r, i, timestampIndex, ticks, true))
                        {
                            heap[heapCount] = i;
                            SiftUp(heap, heapCount, ticks);
                            heapCount++;
                        }
                    }
                    long held = bufferBytes;
                    for (int i = 0; i < k; i++)
                    {
                        held += readers[i].HeldBytes;
                    }
                    result.PeakHeldBytes = held;

                    while (heapCount > 0)
                    {
                        int i = heap[0];
                        TimelineRecordReader r = readers[i];
                        output.Write(r.Record, 0, r.RecordLength);
                        if (!r.HasTerminator)
                        {
                            output.Write(lineEndings[i], 0, lineEndings[i].Length);
                        }
                        result.Rows++;
                        result.RowsPerInput[i]++;
                        if (computerIndex >= 0 && !result.ComputersCapped[i])
                        {
                            string computer = GetField(r.Record, r.RecordLength, computerIndex);
                            if (!string.IsNullOrEmpty(computer) && !seen[i].ContainsKey(computer))
                            {
                                if (seen[i].Count >= maxComputers)
                                {
                                    result.ComputersCapped[i] = true;
                                }
                                else
                                {
                                    seen[i].Add(computer, true);
                                    names[i].Add(computer);
                                }
                            }
                        }
                        if (Advance(r, i, timestampIndex, ticks, false))
                        {
                            SiftDown(heap, heapCount, ticks);
                        }
                        else
                        {
                            heapCount--;
                            heap[0] = heap[heapCount];
                            SiftDown(heap, heapCount, ticks);
                        }
                        held = bufferBytes;
                        for (int j = 0; j < k; j++)
                        {
                            held += readers[j].HeldBytes;
                        }
                        if (held > result.PeakHeldBytes)
                        {
                            result.PeakHeldBytes = held;
                        }
                    }
                    output.Flush(true);
                }
            }
            finally
            {
                for (int i = 0; i < k; i++)
                {
                    if (readers[i] != null)
                    {
                        readers[i].Dispose();
                    }
                }
            }
            for (int i = 0; i < k; i++)
            {
                result.Computers[i] = names[i].ToArray();
            }
            return result;
        }
    }
}
'@

function Initialize-CombinedTimelineType {
    [CmdletBinding()]
    param()

    if (-not ('HayabusaBulkRunner.CombinedTimeline' -as [type])) {
        Add-Type -TypeDefinition $script:CombinedTimelineSource -Language CSharp
    }
}

function Get-CombinedTimelinePath {
    # OutputRoot\combined_timeline.csv
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot
    )

    return (Join-Path -Path $OutputRoot -ChildPath $script:CombinedTimelineName)
}

function Join-CombinedNameList {
    # "A", "A and B", "A, B and C".
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Name
    )

    if ($Name.Count -le 1) {
        return ($Name -join '')
    }
    return ((@($Name | Select-Object -First ($Name.Count - 1)) -join ', ') + ' and ' + $Name[-1])
}

function Test-CombinedPathIsLink {
    # True when Path exists and is a link or junction.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $false
    }
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Invoke-CombinedTimeline {
    <#
    .SYNOPSIS
        Writes OutputRoot\combined_timeline.csv from the hosts the rollup
        counts.
    .DESCRIPTION
        Takes the hosts the rollup counts, Completed or CompletedWithErrors
        with a CSV it could read, in the manifest's order. Every included
        host's CSV must have the same header, and every row a Timestamp in
        Hayabusa's UTC form, in time order. If any of that fails, or the
        output path can't be written safely or there isn't the room,
        nothing is written and any earlier combined_timeline.csv is left as
        it was. The file is written to a temporary file beside it and moved
        into place only once complete.

        Returns Path, Rows and Hosts when built. Otherwise Error holds the
        full reason for the warning and Reason a short one for the console
        and the dashboard. Warnings, a shared computer name among them,
        are in Warnings and are for the caller to write.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Hosts
    )

    $path = Get-CombinedTimelinePath -OutputRoot $OutputRoot
    $temp = "$path.tmp"
    $result = [pscustomobject]@{
        Path     = $null
        Rows     = $null
        Hosts    = $null
        Error    = $null
        Reason   = $null
        Warnings = @()
    }
    $warnings = New-Object System.Collections.Generic.List[string]
    $kept = 'Any earlier combined_timeline.csv was left as it was.'
    $stop = {
        param([string]$Reason, [string]$Message)
        $result.Reason = $Reason
        $result.Error = "Combined timeline not built, $Message"
        $result.Warnings = $warnings.ToArray()
        return $result
    }

    # The rollup's own decision on which hosts have results, in the
    # manifest's order, so ties keep the collections as listed there.
    $included = @($Hosts | Where-Object { $script:ResultStatuses -contains $_.Status } | Sort-Object -Property ManifestIndex)
    if ($included.Count -eq 0) {
        $result.Reason = 'no host has results yet'
        return $result
    }

    foreach ($p in @($path, $temp)) {
        if (Test-CombinedPathIsLink -Path $p) {
            return (& $stop 'the output path is a link or junction' "because $p is a link or junction, which could point anywhere. $kept")
        }
        if (Test-Path -LiteralPath $p -PathType Container) {
            return (& $stop 'a folder is in the way' "because a folder named $(Split-Path -Path $p -Leaf) is in the way in $OutputRoot.")
        }
    }

    Initialize-CombinedTimelineType

    # Every host with a non-empty CSV, with its header. A missing or empty
    # CSV is a host with nothing detected, and adds no rows.
    $inputs = New-Object System.Collections.Generic.List[object]
    $totalBytes = [long]0
    foreach ($h in $included) {
        $csv = (Get-CollectionOutputPath -OutputRoot $OutputRoot -Collection $h.Collection).Csv
        $file = Get-Item -LiteralPath $csv -Force -ErrorAction SilentlyContinue
        if ($null -eq $file -or $file.Length -eq 0) {
            continue
        }
        try {
            $header = [HayabusaBulkRunner.CombinedTimeline]::ReadHeader($csv, $script:CombinedBufferBytes, $script:CombinedMaxRecordBytes)
        }
        catch {
            return (& $stop "a host's timeline can't be read" "because $($h.Collection)'s timeline couldn't be read. $($_.Exception.Message) $kept")
        }
        if ($header.Empty) {
            continue
        }
        $totalBytes += $file.Length
        $inputs.Add([pscustomobject]@{ Collection = [string]$h.Collection; Path = $csv; Header = $header; Key = ($header.Columns -join [char]0) })
    }

    $groups = @($inputs | Group-Object -Property Key)
    if ($groups.Count -gt 1) {
        $parts = foreach ($g in $groups) {
            $columns = @($g.Group[0].Header.Columns | ForEach-Object { ConvertTo-ConsoleText -Text $_ })
            '{0} {1} {2}' -f (Join-CombinedNameList -Name @($g.Group | ForEach-Object { $_.Collection })), $(if ($g.Count -eq 1) { 'has' } else { 'have' }), ($columns -join ', ')
        }
        return (& $stop "the hosts' columns differ" ("because the hosts' timelines don't all have the same columns, so the file would mix layouts. {0}. Rerunning those hosts with -Force under one profile fixes it. {1}" -f ($parts -join '; '), $kept))
    }

    $timestampIndex = -1
    $computerIndex = -1
    if ($inputs.Count -gt 0) {
        $columns = @($inputs[0].Header.Columns)
        $timestampIndex = [array]::IndexOf($columns, 'Timestamp')
        $computerIndex = [array]::IndexOf($columns, 'Computer')
        if ($timestampIndex -lt 0) {
            return (& $stop 'the timelines have no Timestamp column' "because the hosts' timelines have no Timestamp column to order them by. $kept")
        }
    }

    $free = Get-FreeSpace -Path $OutputRoot
    if ($null -ne $free -and $free -lt $totalBytes) {
        return (& $stop 'not enough free space' ("because {0} has {1} free and it needs about {2}, the size of the hosts' timelines together. {3}" -f $OutputRoot, (Format-ConsoleByteSize -Bytes $free), (Format-ConsoleByteSize -Bytes $totalBytes), $kept))
    }

    if (-not $PSCmdlet.ShouldProcess($path, 'Write combined timeline')) {
        return $result
    }

    if (Test-Path -LiteralPath $temp -PathType Leaf) {
        Remove-Item -LiteralPath $temp -Force
    }
    # With no inputs every included host detected nothing, and the merge
    # writes an empty file with no header, as Hayabusa does for one host.
    $merge = $null
    try {
        $merge = [HayabusaBulkRunner.CombinedTimeline]::Merge(
            [string[]]@($inputs | ForEach-Object { $_.Path }), $temp, $timestampIndex, $computerIndex,
            $script:CombinedMaxComputers, $script:CombinedBufferBytes, $script:CombinedMaxRecordBytes)
    }
    catch {
        $inner = $_.Exception
        while ($null -ne $inner.InnerException -and -not ($inner -is [HayabusaBulkRunner.TimelineMergeException])) {
            $inner = $inner.InnerException
        }
        if (Test-Path -LiteralPath $temp -PathType Leaf) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        if ($inner -is [HayabusaBulkRunner.TimelineMergeException]) {
            $who = $inputs[$inner.Input].Collection
            switch ($inner.Kind) {
                'Timestamp' {
                    return (& $stop "a Timestamp isn't in the expected form" "because line $($inner.Line) of $who's timeline has a Timestamp that isn't in Hayabusa's UTC form, $script:CombinedTimestampForm. $kept")
                }
                'Order' {
                    return (& $stop "a host's timeline is out of time order" "because $who's timeline isn't in time order at line $($inner.Line), and the combined file must never be. $kept")
                }
                'Unterminated' {
                    return (& $stop "a host's timeline can't be read" "because $who's timeline has a quoted field starting at line $($inner.Line) that never closes. $kept")
                }
                default {
                    return (& $stop "a host's timeline can't be read" ("because {0}'s timeline has a row longer than {1} at line {2}. {3}" -f $who, (Format-ConsoleByteSize -Bytes $script:CombinedMaxRecordBytes), $inner.Line, $kept))
                }
            }
        }
        return (& $stop 'it could not be written' "because $($inner.Message) $kept")
    }

    Move-FileIntoPlace -Source $temp -Path $path

    # Rows for one computer in two collections can't be told apart in the
    # combined file. Names come from the evidence, so they're sanitised.
    if ($null -ne $merge) {
        $owners = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([System.StringComparer]::OrdinalIgnoreCase)
        $shown = @{}
        for ($i = 0; $i -lt $inputs.Count; $i++) {
            if ($merge.ComputersCapped[$i]) {
                $warnings.Add("Combined timeline: $($inputs[$i].Collection) has more than $script:CombinedMaxComputers computer names, so only the first $script:CombinedMaxComputers were checked against the other collections.")
            }
            foreach ($name in $merge.Computers[$i]) {
                if (-not $owners.ContainsKey($name)) {
                    $owners[$name] = New-Object System.Collections.Generic.List[string]
                    $shown[$name] = $name
                }
                $owners[$name].Add($inputs[$i].Collection)
            }
        }
        foreach ($name in $owners.Keys) {
            $list = $owners[$name]
            if ($list.Count -gt 1) {
                $quantifier = 'all'
                if ($list.Count -eq 2) {
                    $quantifier = 'both'
                }
                $warnings.Add("Combined timeline: $(Join-CombinedNameList -Name $list.ToArray()) $quantifier have rows for computer $(ConvertTo-ConsoleText -Text $shown[$name]), so those rows can't be told apart in it.")
            }
        }
    }

    $result.Path = $path
    $result.Rows = 0
    if ($null -ne $merge) {
        $result.Rows = [long]$merge.Rows
    }
    $result.Hosts = $included.Count
    $result.Warnings = $warnings.ToArray()
    return $result
}

function Format-CombinedRowCount {
    # "1 row", "12 rows".
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Rows
    )

    $n = [long]0
    if ($null -ne $Rows) {
        $n = [long]$Rows
    }
    if ($n -eq 1) {
        return '1 row'
    }
    return ('{0} rows' -f $n.ToString([System.Globalization.CultureInfo]::InvariantCulture))
}
