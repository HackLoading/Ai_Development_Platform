param(
  [string]$WorkspaceRoot = "C:\Users\Atharva Badgujar\Desktop\projects\New folder\Inference Prototype\ai-platform-demo\ai-platform-demo"
)

$ErrorActionPreference = "Stop"

Write-Host "Starting AI demo (one command)..."
Write-Host "Workspace: $WorkspaceRoot"

function ConvertTo-WslPath {
  param([Parameter(Mandatory=$true)][string]$Path)
  # Example: C:\foo\bar -> /mnt/c/foo/bar
  $drive = $Path.Substring(0,1).ToLower()
  $rest = $Path.Substring(2) -replace '\\','/'
  return "/mnt/$drive/$rest"
}

$wslRoot = ConvertTo-WslPath -Path $WorkspaceRoot
$wslRootEscaped = $wslRoot -replace ' ','\ '
Write-Host "Delegating to WSL..."
& wsl bash -lc "cd $wslRootEscaped && bash ./scripts/start-demo-wsl.sh"

