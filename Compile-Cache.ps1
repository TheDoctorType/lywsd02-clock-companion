<#
.SYNOPSIS
    Shared helper (dot-sourced): compile a C# source once, cache the DLL under
    logs\cache keyed by a hash of the source, and load the cached DLL on every
    later start. Saves a csc.exe run per launch of the tray, the Aranet watcher
    and each clock read.
#>
function Import-CachedAssembly {
    param(
        [Parameter(Mandatory)] [string]$Name,        # file stem for the cached DLL
        [Parameter(Mandatory)] [string]$Source,      # C# source text
        [Parameter(Mandatory)] [scriptblock]$References,  # returns reference paths; only run on a cache miss
        [Parameter(Mandatory)] [string]$CacheDir,
        [string]$ProbeType                           # a type the source defines; skip everything if already loaded
    )
    if ($ProbeType -and ($ProbeType -as [type])) { return 'loaded' }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Source))) -replace '-', '').Substring(0, 12)
    $sha.Dispose()
    $dll = Join-Path $CacheDir ("{0}-{1}.dll" -f $Name, $hash)
    if (Test-Path $dll) {
        try { Add-Type -Path $dll -ErrorAction Stop; return 'cache' }
        catch { try { Remove-Item $dll -Force -ErrorAction SilentlyContinue } catch {} }
    }
    $refs = @(& $References)
    try {
        if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
        # drop DLLs built from older source (ones still loaded by a running process stay locked; harmless)
        Get-ChildItem $CacheDir -Filter "$Name-*.dll" -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {} }
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        foreach ($r in $refs) { [void]$cp.ReferencedAssemblies.Add($r) }
        $cp.GenerateInMemory = $false
        $cp.OutputAssembly = $dll
        $cp.CompilerOptions = '/optimize+'
        Add-Type -TypeDefinition $Source -CompilerParameters $cp -ErrorAction Stop
        Add-Type -Path $dll -ErrorAction Stop
        return 'compiled'
    } catch {
        $script:CompileCacheError = $_.Exception.Message
        if ($ProbeType -and ($ProbeType -as [type])) { return 'compiled' }
        # could not write/load the cache - fall back to a plain in-memory compile
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        foreach ($r in $refs) { [void]$cp.ReferencedAssemblies.Add($r) }
        $cp.GenerateInMemory = $true
        Add-Type -TypeDefinition $Source -CompilerParameters $cp -ErrorAction Stop
        return 'memory'
    }
}
