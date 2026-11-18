# =============================================================================
# HeatSafe · vm/criar_vm.ps1 — cria a VM heatsafe-srv no VirtualBox (Windows)
# Uso (PowerShell, na pasta Downloads com a ISO do Ubuntu Server 24.04):
#   powershell -ExecutionPolicy Bypass -File criar_vm.ps1 -Iso "C:\caminho\ubuntu-24.04.x-live-server-amd64.iso"
# Depois: ligar a VM, instalar o Ubuntu (usuário, OpenSSH) e entrar por SSH:
#   ssh -p 2222 <usuario>@localhost
# =============================================================================
param(
  [Parameter(Mandatory = $true)][string]$Iso,
  [string]$Nome = "heatsafe-srv",
  [int]$MemoriaMB = 4096,
  [int]$Cpus = 2,
  [int]$DiscoMB = 25600
)
$ErrorActionPreference = "Stop"
$vbox = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$dir  = Join-Path $env:USERPROFILE "VirtualBox VMs\$Nome"

& $vbox createvm --name $Nome --ostype Ubuntu_64 --register
& $vbox modifyvm $Nome --memory $MemoriaMB --cpus $Cpus --nic1 nat --graphicscontroller vmsvga --vram 16 --boot1 dvd --boot2 disk
& $vbox createmedium disk --filename "$dir\$Nome.vdi" --size $DiscoMB --format VDI
& $vbox storagectl $Nome --name SATA --add sata --controller IntelAhci --portcount 2
& $vbox storageattach $Nome --storagectl SATA --port 0 --device 0 --type hdd --medium "$dir\$Nome.vdi"
& $vbox storageattach $Nome --storagectl SATA --port 1 --device 0 --type dvddrive --medium $Iso
# Redirecionamento de portas do NAT: SSH (2222 -> 22) e web (8080 -> 80)
& $vbox modifyvm $Nome --natpf1 "ssh,tcp,,2222,,22" --natpf1 "web,tcp,,8080,,80"
& $vbox showvminfo $Nome | Select-String "Memory size|Number of CPUs|NIC 1 Rule|SATA"

# Evita que o Windows "freie" a VM em segundo plano (processadores híbridos Intel)
Write-Host "Opcional (PowerShell como administrador):"
Write-Host '  powercfg /powerthrottling disable /path "C:\Program Files\Oracle\VirtualBox\VirtualBoxVM.exe"'
