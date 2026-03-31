param(
  [string]$WorkspaceRoot = "C:\Users\Atharva Badgujar\Desktop\projects\New folder\Inference Prototype\ai-platform-demo\ai-platform-demo"
)

$ErrorActionPreference = "Stop"

function ConvertTo-WslPath {
  param([Parameter(Mandatory=$true)][string]$Path)
  $drive = $Path.Substring(0,1).ToLower()
  $rest = $Path.Substring(2) -replace '\\','/'
  return "/mnt/$drive/$rest"
}

$wslRoot = ConvertTo-WslPath -Path $WorkspaceRoot
$wslRootEscaped = $wslRoot -replace ' ','\ '

Write-Host "Stopping AI demo (one command)..."
& wsl bash -lc "cd $wslRootEscaped && bash ./scripts/stop-demo-wsl.sh"

