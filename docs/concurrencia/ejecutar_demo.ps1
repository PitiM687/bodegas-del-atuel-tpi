# =====================================================================
# docs/concurrencia/ejecutar_demo.ps1
# Demostración de concurrencia "la última botella" (Etapa 2, paso 8).
#
# Corre dos sesiones psql en paralelo (B arranca 0,5 s después de A) para
# tres escenarios y muestra los pasos de ambas ordenados por hora:
#   1. Sin bloqueo (leer -> decidir -> escribir)
#   2. Con SELECT ... FOR UPDATE (Anexo A.8)
#   3. El sistema real: venta por INSERT en renglon_comprobante (trigger RN-09)
# Usa una fila real de stock_sala, la pone en 1 botella antes de cada
# escenario y al final deja la base exactamente como estaba.
#
# Uso (desde la raíz del repo, con PGHOST/PGUSER/PGPASSWORD definidos o un .env):
#   powershell -ExecutionPolicy Bypass -File docs\concurrencia\ejecutar_demo.ps1
# Resultado: docs\concurrencia\resultado_demo.txt
# =====================================================================
$ErrorActionPreference = 'Stop'
$dir  = $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $dir)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PGCLIENTENCODING = 'UTF8'

# Conexión: variables de entorno o .env de la raíz
$envFile = Join-Path $repo '.env'
if (Test-Path $envFile) {
    foreach ($l in Get-Content $envFile) {
        if ($l -match '^\s*(PG[A-Z]*)\s*=\s*(.+)$' -and -not [Environment]::GetEnvironmentVariable($Matches[1])) {
            Set-Item "env:$($Matches[1])" $Matches[2].Trim()
        }
    }
}
$env:PGDATABASE = 'bodegas_atuel'
$psql = (Get-Command psql -ErrorAction SilentlyContinue).Source
if (-not $psql) {
    $psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' | Sort-Object { [double]($_.Directory.Parent.Name) } -Descending |
            Select-Object -First 1 -ExpandProperty FullName
}
function Q([string]$sql) { (& $psql -w -q -Atc $sql) -join "" }

$salida = New-Object System.Collections.Generic.List[string]
function Out([string]$t) { Write-Host $t; $salida.Add($t) }

$fila = (Q "SELECT id_sala || ' ' || cod_vino || ' ' || cantidad FROM stock_sala WHERE id_sala = 1 AND cantidad > 0 ORDER BY cod_vino LIMIT 1").Split(' ')
$sala, $vino, $orig = $fila[0], $fila[1], $fila[2]
$cliente = Q "SELECT min(id_cliente) FROM cliente WHERE tipo = 'socio'"
$maxNro  = Q "SELECT COALESCE(max(nro), 0) FROM comprobante"
Out "Demostración de concurrencia · $(Get-Date -Format 'yyyy-MM-dd HH:mm') · $(Q 'SELECT version()')"
Out "Fila usada: sala $sala, vino $vino (stock original $orig). Se pone en 1 botella antes de cada escenario."

$escenarios = @(
    @('1a_sin_bloqueo_sesion_A.sql', '1b_sin_bloqueo_sesion_B.sql', '1 · SIN bloqueo (leer -> decidir -> escribir)'),
    @('2a_for_update_sesion_A.sql',  '2b_for_update_sesion_B.sql',  '2 · CON SELECT ... FOR UPDATE'),
    @('3a_trigger_sesion_A.sql',     '3b_trigger_sesion_B.sql',     '3 · Sistema real: INSERT de renglón con el trigger de RN-09')
)
try {
    foreach ($e in $escenarios) {
        Q "UPDATE stock_sala SET cantidad = 1 WHERE id_sala = $sala AND cod_vino = $vino" | Out-Null
        Out ''; Out "=== Escenario $($e[2]) ==="
        $vars = @('-w', '-v', "sala=$sala", '-v', "vino=$vino", '-v', "cliente=$cliente")
        $outA = Join-Path $env:TEMP 'demo_a.txt'; $outB = Join-Path $env:TEMP 'demo_b.txt'
        $pa = Start-Process $psql -ArgumentList ($vars + @('-f', "`"$(Join-Path $dir $e[0])`"")) -NoNewWindow -PassThru `
                  -RedirectStandardOutput $outA -RedirectStandardError "$outA.err"
        Start-Sleep -Milliseconds 500
        $pb = Start-Process $psql -ArgumentList ($vars + @('-f', "`"$(Join-Path $dir $e[1])`"")) -NoNewWindow -PassThru `
                  -RedirectStandardOutput $outB -RedirectStandardError "$outB.err"
        $pa.WaitForExit(); $pb.WaitForExit()
        Get-Content $outA, $outB -Encoding UTF8 | Where-Object { $_ -match '^\d\d:' } | Sort-Object | ForEach-Object { Out $_ }
        Out "Stock final: $(Q "SELECT cantidad FROM stock_sala WHERE id_sala = $sala AND cod_vino = $vino") botella(s)"
    }
} finally {
    # Deja la base como estaba: borra los comprobantes de la demo y repone el stock original.
    Q "DELETE FROM comprobante WHERE nro > $maxNro" | Out-Null
    Q "UPDATE stock_sala SET cantidad = $orig WHERE id_sala = $sala AND cod_vino = $vino" | Out-Null
    Out ''; Out "Base restaurada: stock de la fila = $(Q "SELECT cantidad FROM stock_sala WHERE id_sala = $sala AND cod_vino = $vino"), comprobantes = $(Q 'SELECT count(*) FROM comprobante')"
    $salida | Set-Content (Join-Path $dir 'resultado_demo.txt') -Encoding UTF8
}
