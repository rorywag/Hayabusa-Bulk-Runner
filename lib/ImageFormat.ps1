# Checks an evidence image's own format headers before anything opens it as
# a disk. A differencing disk names a parent, and Windows opens that parent
# when the image is attached or a child is made from it, wherever it points,
# so an image with a parent is refused. The image is hostile, so every
# offset and length in it is checked against the file before it's used, the
# entry counts are capped at the format's own limits, and anything that
# doesn't parse cleanly is refused rather than guessed at.
#
# VHD follows Microsoft's Virtual Hard Disk Image Format Specification and
# VHDX follows MS-VHDX. Both are read through one stream opened read-only and
# sharing only reads, so the check never writes to the image.

$script:ImageFormatSource = @'
namespace HayabusaBulkRunner
{
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Text;

    public sealed class DiskImageInspection
    {
        public string Format;
        public bool HasParent;
        public string Problem;
    }

    internal sealed class MalformedImageException : Exception
    {
        public MalformedImageException(string message) : base(message)
        {
        }
    }

    public static class DiskImageInspector
    {
        // MS-VHDX caps both the region table and the metadata table at
        // 2047 entries, which is also all that fits in their 64 KB.
        private const int MaxTableEntries = 2047;
        private const long Kb64 = 64L * 1024;
        private const long Mb1 = 1024L * 1024;

        private static readonly Guid BatRegion = new Guid("2DC27766-F623-4200-9D64-115E9BFD4A08");
        private static readonly Guid MetadataRegion = new Guid("8B7CA206-4790-4B9A-B8FE-575F050F886E");
        private static readonly Guid FileParameters = new Guid("CAA16737-FA36-4D43-B3B6-33F0AA44E76B");
        private static readonly Guid ParentLocator = new Guid("A8D35F2D-B30B-454D-ABF7-D3D84834AB0C");
        private static readonly Guid[] KnownMetadata = new Guid[]
        {
            FileParameters,
            new Guid("2FA54224-CD1B-4876-B211-5DBED83BF4B8"),
            new Guid("BECA12AB-B2E6-4523-93EF-C309E000C746"),
            new Guid("8141BF1D-A96F-4709-BA47-F233A8FAAB5F"),
            new Guid("CDA348C7-445D-4471-9CC9-E9885251C556"),
            ParentLocator
        };

        private static readonly uint[] Crc32CTable = BuildCrc32CTable();

        private static uint[] BuildCrc32CTable()
        {
            uint[] table = new uint[256];
            for (uint n = 0; n < 256; n++)
            {
                uint c = n;
                for (int k = 0; k < 8; k++)
                {
                    c = (c & 1) != 0 ? 0x82F63B78u ^ (c >> 1) : c >> 1;
                }
                table[n] = c;
            }
            return table;
        }

        // CRC-32C over data with the four checksum bytes at checksumAt
        // counted as zero, as MS-VHDX computes it.
        public static uint Crc32C(byte[] data, int checksumAt)
        {
            uint c = 0xFFFFFFFFu;
            for (int i = 0; i < data.Length; i++)
            {
                byte b = (i >= checksumAt && i < checksumAt + 4) ? (byte)0 : data[i];
                c = Crc32CTable[(c ^ b) & 0xFF] ^ (c >> 8);
            }
            return ~c;
        }

        public static DiskImageInspection Inspect(string path)
        {
            DiskImageInspection result = new DiskImageInspection();
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.RandomAccess))
            {
                long length = stream.Length;
                try
                {
                    byte[] start = length >= 8 ? ReadAt(stream, 0, 8, length) : new byte[0];
                    if (start.Length == 8 && Encoding.ASCII.GetString(start) == "vhdxfile")
                    {
                        result.Format = "VHDX";
                        result.HasParent = VhdxHasParent(stream, length);
                    }
                    else
                    {
                        result.Format = "VHD";
                        result.HasParent = VhdHasParent(stream, length);
                    }
                }
                catch (MalformedImageException e)
                {
                    result.Problem = e.Message;
                }
            }
            return result;
        }

        private static byte[] ReadAt(FileStream stream, long offset, long count, long length)
        {
            if (offset < 0 || count < 0 || count > int.MaxValue || offset > length || count > length - offset)
            {
                throw new MalformedImageException("it points past the end of the file");
            }
            byte[] buffer = new byte[(int)count];
            stream.Position = offset;
            int done = 0;
            while (done < buffer.Length)
            {
                int n = stream.Read(buffer, done, buffer.Length - done);
                if (n <= 0)
                {
                    throw new MalformedImageException("the file ended early");
                }
                done += n;
            }
            return buffer;
        }

        private static uint BigEndian32(byte[] b, int at)
        {
            return ((uint)b[at] << 24) | ((uint)b[at + 1] << 16) | ((uint)b[at + 2] << 8) | b[at + 3];
        }

        private static ulong BigEndian64(byte[] b, int at)
        {
            return ((ulong)BigEndian32(b, at) << 32) | BigEndian32(b, at + 4);
        }

        private static bool Ascii(byte[] b, int at, string text)
        {
            if (at < 0 || at + text.Length > b.Length)
            {
                return false;
            }
            for (int i = 0; i < text.Length; i++)
            {
                if (b[at + i] != (byte)text[i])
                {
                    return false;
                }
            }
            return true;
        }

        private static Guid GuidAt(byte[] b, int at)
        {
            byte[] g = new byte[16];
            Buffer.BlockCopy(b, at, g, 0, 16);
            return new Guid(g);
        }

        // ---- VHD ----

        // The footer's disk type, after checking its cookie and checksum.
        // Versions before Virtual PC 2004 wrote a 511-byte footer.
        private static uint VhdFooterType(byte[] footer, string where)
        {
            if (!Ascii(footer, 0, "conectix"))
            {
                throw new MalformedImageException("its " + where + " has no VHD cookie");
            }
            uint sum = 0;
            for (int i = 0; i < footer.Length; i++)
            {
                if (i < 64 || i > 67)
                {
                    sum += footer[i];
                }
            }
            if (~sum != BigEndian32(footer, 64))
            {
                throw new MalformedImageException("its " + where + " checksum doesn't match");
            }
            uint type = BigEndian32(footer, 60);
            if (type != 2 && type != 3 && type != 4)
            {
                throw new MalformedImageException("its " + where + " gives disk type " + type + ", which isn't fixed, dynamic or differencing");
            }
            return type;
        }

        private static bool VhdHasParent(FileStream stream, long length)
        {
            if (length < 512)
            {
                throw new MalformedImageException("it's too small to hold a VHD footer");
            }
            byte[] footer = ReadAt(stream, length - 512, 512, length);
            if (!Ascii(footer, 0, "conectix"))
            {
                byte[] shortFooter = ReadAt(stream, length - 511, 511, length);
                if (!Ascii(shortFooter, 0, "conectix"))
                {
                    throw new MalformedImageException("it has no VHD footer at the end of the file");
                }
                footer = new byte[512];
                Buffer.BlockCopy(shortFooter, 0, footer, 0, 511);
            }
            uint type = VhdFooterType(footer, "footer");

            // A dynamic or differencing disk keeps a copy of the footer at
            // the start. Either copy saying differencing is enough to refuse,
            // and two copies that disagree aren't trusted.
            byte[] head = ReadAt(stream, 0, 512, length);
            if (Ascii(head, 0, "conectix"))
            {
                uint copyType = VhdFooterType(head, "footer copy at the start");
                if (copyType == 4)
                {
                    return true;
                }
                if (copyType != type)
                {
                    throw new MalformedImageException("its two footers give different disk types");
                }
            }
            if (type == 4)
            {
                return true;
            }
            if (type == 3)
            {
                ulong dataOffset = BigEndian64(footer, 16);
                if (dataOffset > (ulong)long.MaxValue)
                {
                    throw new MalformedImageException("its dynamic disk header offset is out of range");
                }
                byte[] header = ReadAt(stream, (long)dataOffset, 1024, length);
                if (!Ascii(header, 0, "cxsparse"))
                {
                    throw new MalformedImageException("its dynamic disk header has no cookie");
                }
                // The eight parent locators only belong to a differencing
                // disk, so a dynamic disk carrying one isn't trusted.
                for (int i = 0; i < 8; i++)
                {
                    if (BigEndian32(header, 576 + (i * 24)) != 0)
                    {
                        throw new MalformedImageException("its dynamic disk header carries a parent locator");
                    }
                }
            }
            return false;
        }

        // ---- VHDX ----

        private static bool VhdxHasParent(FileStream stream, long length)
        {
            if (length < Mb1)
            {
                throw new MalformedImageException("it's too small to hold the VHDX headers");
            }

            // The current header is the valid one with the higher sequence
            // number. Its fields aren't needed beyond that, but a file with
            // neither header valid isn't a VHDX Windows will open as such.
            byte[] h1 = ReadAt(stream, Kb64, 4096, length);
            byte[] h2 = ReadAt(stream, 2 * Kb64, 4096, length);
            bool v1 = VhdxHeaderValid(h1);
            bool v2 = VhdxHeaderValid(h2);
            if (!v1 && !v2)
            {
                throw new MalformedImageException("neither of its VHDX headers is valid");
            }
            if (v1 && v2 && BitConverter.ToUInt64(h1, 8) == BitConverter.ToUInt64(h2, 8) && !SameBytes(h1, h2))
            {
                throw new MalformedImageException("its two VHDX headers have the same sequence number but differ");
            }

            // Both region tables should be the same. One may be damaged, but
            // two valid tables that disagree aren't trusted.
            byte[] r1 = ReadAt(stream, 3 * Kb64, Kb64, length);
            byte[] r2 = ReadAt(stream, 4 * Kb64, Kb64, length);
            bool rv1 = VhdxRegionTableValid(r1);
            bool rv2 = VhdxRegionTableValid(r2);
            if (!rv1 && !rv2)
            {
                throw new MalformedImageException("neither of its region tables is valid");
            }
            if (rv1 && rv2 && !SameBytes(r1, r2))
            {
                throw new MalformedImageException("its two region tables differ");
            }
            byte[] regions = rv1 ? r1 : r2;

            uint regionCount = BitConverter.ToUInt32(regions, 8);
            long metaOffset = -1;
            long metaLength = 0;
            bool batSeen = false;
            for (int i = 0; i < (int)regionCount; i++)
            {
                int at = 16 + (i * 32);
                Guid id = GuidAt(regions, at);
                ulong fileOffset = BitConverter.ToUInt64(regions, at + 16);
                uint regionLength = BitConverter.ToUInt32(regions, at + 24);
                uint required = BitConverter.ToUInt32(regions, at + 28);
                if (fileOffset < (ulong)Mb1 || fileOffset % (ulong)Mb1 != 0 || regionLength == 0 || regionLength % (uint)Mb1 != 0 || fileOffset > (ulong)length || regionLength > (ulong)length - fileOffset)
                {
                    throw new MalformedImageException("a region lies outside the file or isn't aligned");
                }
                if (id == MetadataRegion)
                {
                    if (metaOffset >= 0)
                    {
                        throw new MalformedImageException("it lists the metadata region twice");
                    }
                    metaOffset = (long)fileOffset;
                    metaLength = regionLength;
                }
                else if (id == BatRegion)
                {
                    if (batSeen)
                    {
                        throw new MalformedImageException("it lists the block allocation table twice");
                    }
                    batSeen = true;
                }
                else if ((required & 1) != 0)
                {
                    throw new MalformedImageException("it has a required region the tool doesn't know");
                }
            }
            if (metaOffset < 0 || !batSeen)
            {
                throw new MalformedImageException("its region table lacks the metadata region or the block allocation table");
            }
            if (metaLength < Kb64)
            {
                throw new MalformedImageException("its metadata region is too small");
            }

            byte[] table = ReadAt(stream, metaOffset, Kb64, length);
            if (!Ascii(table, 0, "metadata"))
            {
                throw new MalformedImageException("its metadata table has no signature");
            }
            int entryCount = BitConverter.ToUInt16(table, 10);
            if (entryCount > MaxTableEntries)
            {
                throw new MalformedImageException("its metadata table lists more entries than the format allows");
            }

            bool hasParent = false;
            bool fileParametersSeen = false;
            List<Guid> seen = new List<Guid>();
            for (int i = 0; i < entryCount; i++)
            {
                int at = 32 + (i * 32);
                Guid id = GuidAt(table, at);
                uint itemOffset = BitConverter.ToUInt32(table, at + 16);
                uint itemLength = BitConverter.ToUInt32(table, at + 20);
                uint flags = BitConverter.ToUInt32(table, at + 24);
                if (seen.Contains(id))
                {
                    throw new MalformedImageException("its metadata table lists an item twice");
                }
                seen.Add(id);
                if (itemLength > 0 && (itemOffset < Kb64 || itemOffset > metaLength || itemLength > metaLength - itemOffset))
                {
                    throw new MalformedImageException("a metadata item lies outside the metadata region");
                }
                if (id == ParentLocator)
                {
                    hasParent = true;
                }
                else if (id == FileParameters)
                {
                    if (itemLength != 8)
                    {
                        throw new MalformedImageException("its file parameters item isn't 8 bytes");
                    }
                    byte[] parameters = ReadAt(stream, metaOffset + itemOffset, 8, length);
                    if ((BitConverter.ToUInt32(parameters, 4) & 2) != 0)
                    {
                        hasParent = true;
                    }
                    fileParametersSeen = true;
                }
                else if (Array.IndexOf(KnownMetadata, id) < 0 && (flags & 4) != 0)
                {
                    throw new MalformedImageException("it has a required metadata item the tool doesn't know");
                }
            }
            if (!fileParametersSeen)
            {
                throw new MalformedImageException("its metadata has no file parameters item");
            }
            return hasParent;
        }

        private static bool VhdxHeaderValid(byte[] header)
        {
            return Ascii(header, 0, "head")
                && Crc32C(header, 4) == BitConverter.ToUInt32(header, 4)
                && BitConverter.ToUInt16(header, 66) == 1;
        }

        private static bool VhdxRegionTableValid(byte[] table)
        {
            return Ascii(table, 0, "regi")
                && Crc32C(table, 4) == BitConverter.ToUInt32(table, 4)
                && BitConverter.ToUInt32(table, 8) <= MaxTableEntries;
        }

        private static bool SameBytes(byte[] a, byte[] b)
        {
            if (a.Length != b.Length)
            {
                return false;
            }
            for (int i = 0; i < a.Length; i++)
            {
                if (a[i] != b[i])
                {
                    return false;
                }
            }
            return true;
        }
    }
}
'@

function Initialize-ImageFormatType {
    [CmdletBinding()]
    param()

    if (-not ('HayabusaBulkRunner.DiskImageInspector' -as [type])) {
        Add-Type -TypeDefinition $script:ImageFormatSource -Language CSharp
    }
}

function Assert-ImageHasNoParent {
    <#
    .SYNOPSIS
        Refuses an evidence image that's a differencing disk, or whose
        format headers don't parse cleanly.
    .DESCRIPTION
        Reads only the image's own headers, through a stream opened
        read-only and sharing only reads, before it's hashed, given to
        diskpart or mounted. The format is taken from the file's content,
        and a file whose content doesn't match its extension is refused
        too, since Windows picks the format by extension.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    Initialize-ImageFormatType
    try {
        $inspection = [HayabusaBulkRunner.DiskImageInspector]::Inspect((Get-ExtendedLengthPath -Path $ImagePath))
    }
    catch {
        throw "Could not read $ImagePath to check its format, so it isn't mounted: $($_.Exception.Message)"
    }
    $extension = [System.IO.Path]::GetExtension($ImagePath).TrimStart('.').ToUpperInvariant()
    if ($null -ne $inspection.Problem) {
        throw "$ImagePath isn't a well-formed $extension image, because $($inspection.Problem), so it isn't mounted."
    }
    if ($inspection.Format -ne $extension) {
        throw "$ImagePath is a $($inspection.Format) file named as a $extension, so it isn't mounted."
    }
    if ($inspection.HasParent) {
        throw "$ImagePath is a differencing disk, and the tool won't open the parent it points to, so it isn't mounted. Merge it into a standalone image and rerun."
    }
}
