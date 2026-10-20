# Test and diagnostic materials use category-first directories. Application
# settings, sources and final releases retain their project-local locations.
function Get-ProjectMaterialsRoot {
    param([string]$ProjectRoot)
    $drive = if ([IO.Directory]::GetLogicalDrives() -contains 'D:\') { 'D:\' } else { 'C:\' }
    return [IO.Path]::Combine($drive, 'work')
}

function Get-ProjectMaterialDirectory {
    param([Parameter(Mandatory = $true, Position = 0)][string]$ProjectRoot,
          [Parameter(Mandatory = $true, Position = 1)][string]$Category)
    $source = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $projectName = [IO.Path]::GetFileName($source)
    if (-not $projectName) { throw 'A project directory is required, not a drive root.' }
    $canonical = switch ($Category.ToLowerInvariant()) {
        'forme' { 'Forme' }
        'workspace' { 'Workspace' }
        'trash' { 'Trash' }
        'snapshots' { 'Snapshots' }
        default { throw "Unknown assistant material category: $Category" }
    }
    return [IO.Path]::Combine((Get-ProjectMaterialsRoot $source), $canonical, $projectName)
}

function Join-ProjectMaterialPath {
    param([Parameter(Mandatory = $true, Position = 0)][string]$Path,
          [Parameter(Mandatory = $true, Position = 1)][string]$ChildPath)
    if ([IO.Path]::IsPathRooted($ChildPath) -or $ChildPath.Contains(':')) {
        throw "An unrooted project-relative path is required: $ChildPath"
    }
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $parts = $ChildPath -split '[\\/]', 2
    if ($parts[0] -iin @('Forme', 'Workspace', 'Trash', 'Snapshots')) {
        $root = Get-ProjectMaterialDirectory $root $parts[0]
        $relative = if ($parts.Count -eq 2) { $parts[1] } else { '' }
    } else {
        # Installfiles, sources and application data remain inside the project.
        $relative = $ChildPath
    }
    $result = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $relative))
    if ($result -ne $root -and -not $result.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the permitted project area: $ChildPath"
    }
    return $result
}

function Test-ProjectMaterialPath {
    param([string]$Path, [string]$ProjectRoot)
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $roots = @([IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/'))
        foreach ($category in @('Forme', 'Workspace', 'Trash', 'Snapshots')) {
            $roots += Get-ProjectMaterialDirectory $ProjectRoot $category
        }
        foreach ($root in $roots) {
            if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    } catch { return $false }
    return $false
}

function Assert-ProjectTestPath {
    param([string]$Path, [string]$ProjectRoot)
    if (-not (Test-ProjectMaterialPath $Path $ProjectRoot)) {
        throw "Path is outside this project's permitted test areas: $Path"
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}
