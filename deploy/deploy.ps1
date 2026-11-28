# CD script - TV4 (W5): rolling update + tu dong rollback khi that bai
# Vi du: .\deploy\deploy.ps1 -Service api-service -Tag v1.0.1
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Service = "api-service",
    [string]$ImageName = "",          # de trong = nt533-<Service>; sau nay doi thanh <dockerhub>/<Service>
    [int]$TimeoutSec = 180
)

# Quy uoc cua TV3: vX.Y.Z hoac vX.Y.Z-<short_sha>, cam :latest
if ($Tag -notmatch '^v\d+\.\d+\.\d+(-[0-9a-f]{7,40})?$') {
    Write-Host "Tag '$Tag' sai quy uoc (vX.Y.Z hoac vX.Y.Z-<sha>). Khong deploy." -ForegroundColor Red
    exit 2
}
if ($ImageName -eq "") { $ImageName = "nt533-$Service" }
$image = "${ImageName}:${Tag}"

$current = kubectl get deployment $Service -o jsonpath="{.spec.template.spec.containers[0].image}"
Write-Host "Dang chay : $current"
Write-Host "Deploy    : $image"
if ($current -eq $image) { Write-Host "Image da la ban nay, bo qua."; exit 0 }

$sw = [Diagnostics.Stopwatch]::StartNew()
kubectl set image deployment/$Service "$Service=$image"
if ($LASTEXITCODE -ne 0) { Write-Host "set image that bai" -ForegroundColor Red; exit 1 }
kubectl annotate deployment/$Service kubernetes.io/change-cause="deploy $image ($(Get-Date -Format s))" --overwrite | Out-Null

kubectl rollout status deployment/$Service --timeout="${TimeoutSec}s"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Rollout THAT BAI sau $([int]$sw.Elapsed.TotalSeconds)s -> tu dong rollback ve $current" -ForegroundColor Yellow
    kubectl rollout undo deployment/$Service
    kubectl rollout status deployment/$Service --timeout="${TimeoutSec}s"
    exit 1
}

Write-Host "Rollout THANH CONG trong $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor Green
kubectl rollout history deployment/$Service