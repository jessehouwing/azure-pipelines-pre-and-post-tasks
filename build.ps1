$Source = @”
    using System;
    using System.Security.Cryptography;
    using System.Text;

    public static class UUIDv5
    {
        public static Guid Create(Guid namespaceId, string name)
        {
            if (name == null)
                throw new ArgumentNullException("name");

            // convert the name to a sequence of octets (as defined by the standard or conventions of its namespace) (step 3)
            // ASSUME: UTF-8 encoding is always appropriate
            byte[] nameBytes = Encoding.UTF8.GetBytes(name);

            // convert the namespace UUID to network order (step 3)
            byte[] namespaceBytes = namespaceId.ToByteArray();
            SwapByteOrder(namespaceBytes);

            // comput the hash of the name space ID concatenated with the name (step 4)
            byte[] hash;
            using (HashAlgorithm algorithm =  SHA1.Create())
            {
                algorithm.TransformBlock(namespaceBytes, 0, namespaceBytes.Length, null, 0);
                algorithm.TransformFinalBlock(nameBytes, 0, nameBytes.Length);
                hash = algorithm.Hash;
            }

            // most bytes from the hash are copied straight to the bytes of the new GUID (steps 5-7, 9, 11-12)
            byte[] newGuid = new byte[16];
            Array.Copy(hash, 0, newGuid, 0, 16);

            // set the four most significant bits (bits 12 through 15) of the time_hi_and_version field to the appropriate 4-bit version number from Section 4.1.3 (step 8)
            newGuid[6] = (byte)((newGuid[6] & 0x0F) | (5 << 4));

            // set the two most significant bits (bits 6 and 7) of the clock_seq_hi_and_reserved to zero and one, respectively (step 10)
            newGuid[8] = (byte)((newGuid[8] & 0x3F) | 0x80);

            // convert the resulting UUID to local byte order (step 13)
            SwapByteOrder(newGuid);
            return new Guid(newGuid);
        }

        /// <summary>
        /// The namespace for fully-qualified domain names (from RFC 4122, Appendix C).
        /// </summary>
        public static readonly Guid DnsNamespace = new Guid("6ba7b810-9dad-11d1-80b4-00c04fd430c8");

        /// <summary>
        /// The namespace for URLs (from RFC 4122, Appendix C).
        /// </summary>
        public static readonly Guid UrlNamespace = new Guid("6ba7b811-9dad-11d1-80b4-00c04fd430c8");

        /// <summary>
        /// The namespace for ISO OIDs (from RFC 4122, Appendix C).
        /// </summary>
        public static readonly Guid IsoOidNamespace = new Guid("6ba7b812-9dad-11d1-80b4-00c04fd430c8");

        // Converts a GUID (expressed as a byte array) to/from network order (MSB-first).
        internal static void SwapByteOrder(byte[] guid)
        {
            SwapBytes(guid, 0, 3);
            SwapBytes(guid, 1, 2);
            SwapBytes(guid, 4, 5);
            SwapBytes(guid, 6, 7);
        }

        private static void SwapBytes(byte[] guid, int left, int right)
        {
            byte temp = guid[left];
            guid[left] = guid[right];
            guid[right] = temp;
        }
    }
“@

Add-Type -TypeDefinition $Source -Language CSharp 


if (Test-Path "_build")
{
    rd _build -force -Recurse
}

$outputDir = md _build -force

$extensionManifest = gc "vss-extension.json" | ConvertFrom-Json
$extensionManifest.contributions = @()

if (Test-Path -path azure-pipelines-tasks)
{
    & git pull --all
}
else 
{
    & git clone https://github.com/microsoft/azure-pipelines-tasks.git
}

cd azure-pipelines-tasks
git config --local pager.branch false
$branches = & git branch -r
$version = (($branches | Select-String -pattern "(?<=origin/releases/m)\d+$").Matches) | %{ [int32]$_.Value } | measure-object -maximum
$version = $version.Maximum

& git reset --hard origin/releases/m$version

npm install

$tasksToBuild = @("BashV3", "CmdLineV2", "PowerShellV2")

Write-Host "Building tasks..."
foreach ($task in $tasksToBuild)
{
    Write-Host "Building $task..."
    node make.js build --task $task
    Write-Host "Building $task done."

    $taskManifests = @("task.json", "task.loc.json")

    # Generate Pre-Tasks
    Write-Host "Generating Pre-tasks..."

    $taskDir = "$outputDir/Pre/$task"
    copy "./_build/Tasks/$task" $taskDir -Recurse

    foreach ($taskManifest in $taskManifests)
    {
        $manifestPath = "$taskDir/$taskManifest"
        $manifest = (gc $manifestPath) | ConvertFrom-Json
        $manifest.name = "Pre-$($manifest.name)"
        if ($taskManifest -eq "task.json")
        {
            $manifest.friendlyName = "$($manifest.friendlyName) (Pre-Job)"
            Write-Host "Updating resources..."
            $resourceFiles = dir "$outputDir\Pre\$task\Strings\resources.resjson\resources.resjson" -recurse
            foreach ($resourceFile in $resourceFiles)
            {
                $resources = (gc $resourceFile) | ConvertFrom-Json
                $resources."loc.friendlyName" = $manifest.friendlyName
                $resources | ConvertTo-Json -depth 100 | Out-File $resourceFile -Encoding utf8NoBOM
            }
        }
        $manifest.id = [UUIDv5]::Create([guid]$manifest.id, [string]$manifest.name).ToString()
        $manifest.author = "Jesse Houwing"
        $manifest | Add-Member -MemberType NoteProperty -Name "prejobexecution" -Value $manifest.execution
        $manifest.PSObject.Properties.Remove('execution')
        $manifest | ConvertTo-Json -depth 100 | Out-File $manifestPath -Encoding utf8NoBOM
    }
 

    Write-Host "Updating contributions..."
    $extensionManifest.contributions += @{
        "id" = "Pre-$task"
        "type" = "ms.vss-distributed-task.task"
        "targets" = @("ms.vss-distributed-task.tasks")
        "properties" = @{
            "name" = "_build/Pre/$task"
        }
    }

    # Generate Post-Tasks
    Write-Host "Generating Post-tasks..."

    $taskDir = "$outputDir/Post/$task"
    copy "./_build/Tasks/$task" $taskDir -Recurse

    foreach ($taskManifest in $taskManifests)
    {
        $manifestPath = "$taskDir/$taskManifest"
        $manifest = (gc $manifestPath) | ConvertFrom-Json
        $manifest.name = "Post-$($manifest.name)"
        if ($taskManifest -eq "task.json")
        {
            $manifest.friendlyName = "$($manifest.friendlyName) (Post-Job)"
            Write-Host "Updating resources..."
            $resourceFiles = dir "$outputDir\Post\$task\Strings\resources.resjson\resources.resjson" -recurse
            foreach ($resourceFile in $resourceFiles)
            {
                $resources = (gc $resourceFile) | ConvertFrom-Json
                $resources."loc.friendlyName" = $manifest.friendlyName
                $resources | ConvertTo-Json -depth 100 | Out-File $resourceFile -Encoding utf8NoBOM
            }
        }
        $manifest.id = [UUIDv5]::Create([guid]$manifest.id, [string]$manifest.name).ToString()
        $manifest.author = "Jesse Houwing"
        $manifest | Add-Member -MemberType NoteProperty -Name "postjobexecution" -Value $manifest.execution
        $manifest.PSObject.Properties.Remove('execution')
        $manifest | ConvertTo-Json -depth 100 | Out-File $manifestPath -Encoding utf8NoBOM
    }



    Write-Host "Updating contributions..."
    $extensionManifest.contributions += @{
        "id" = "Post-$task"
        "type" = "ms.vss-distributed-task.task"
        "targets" = @("ms.vss-distributed-task.tasks")
        "properties" = @{
            "name" = "_build/Post/$task"
        }
    }
}

# Generate vss-extension.json
cd ..

$extensionManifest.version = "1.$version.0"
$extensionManifest | ConvertTo-Json -depth 100 | Out-File "vss-extension.json" -Encoding utf8NoBOM

& npm install tfx-cli -g
& tfx extension create
