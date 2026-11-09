<#
.SYNOPSIS
    Identifies the spoken language of unnamed audio tracks in video files using Whisper
    and renames/tags those tracks accordingly.

.DESCRIPTION
    Scans a folder (recursively by default) for video files. For every audio track whose
    title does not already mention a language, short random excerpts of that track are
    decoded directly from the container (seek + decode only the excerpt - the track is
    never fully extracted), silence is stripped, and the excerpts are run through Whisper
    language detection. Votes from all excerpts are combined; if the result is confident
    enough, the track's language tag and title are written:

      * MKV / WebM / MKA : in place via mkvpropedit (instant, no remux)
      * other containers : lossless ffmpeg remux (-c copy) to a temp file, verified, swapped

    All dependencies (ffmpeg, ffprobe, whisper.cpp, Whisper model, mkvpropedit) are downloaded
    once into the .\tools folder next to this script, so the whole folder is portable.

.EXAMPLE
    .\AudiotrackID.ps1 "D:\Movies"
.EXAMPLE
    .\AudiotrackID.ps1 "D:\Movies" -DryRun -Model medium -Samples 8
.EXAMPLE
    .\AudiotrackID.ps1 -Setup            # just download all tools (prepare an offline copy)
#>
[CmdletBinding()]
param(
    # Folders and/or individual video files to process.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path,

    # Whisper model: tiny, base, small, medium, large-v3, large-v3-turbo (multilingual only).
    [string]$Model = 'small',

    # Larger model used as a second opinion when the main model is below -VerifyBelow confidence.
    # It re-checks the same excerpts (no extra decoding). Use -VerifyModel '' to disable.
    [string]$VerifyModel = 'large-v3-turbo-q5_0',

    # Confidence (0-1) under which the -VerifyModel second opinion is requested.
    [ValidateRange(0.0, 1.0)][double]$VerifyBelow = 0.9,

    # Where Whisper runs. Auto = benchmark CPU and every Vulkan GPU once per machine/model and use
    # the fastest (cached in tools\device-cache.json); Gpu = fastest GPU without the CPU comparison.
    [ValidateSet('Auto', 'Cpu', 'Gpu')][string]$Device = 'Auto',

    # Number of random excerpts per track (a second round is taken if the result is unclear).
    [ValidateRange(1, 50)][int]$Samples = 6,

    # Seconds of (silence-stripped) audio per excerpt. Whisper looks at max 30 s.
    [ValidateRange(5, 30)][int]$SampleSeconds = 30,

    # Minimum combined confidence (0-1) required to write the result.
    [ValidateRange(0.0, 1.0)][double]$MinConfidence = 0.6,

    # Only show what would be done, don't modify files.
    [switch]$DryRun,

    # Run Whisper on all audio tracks, even those whose title already contains a language.
    [switch]$Force,

    # How the language appears in track titles: Name = "Czech", Iso = "cze", IsoUpper = "CZE".
    [ValidateSet('Name', 'Iso', 'IsoUpper')][string]$NameFormat = 'Name',

    # Also rename tracks whose title already names a language, into the -NameFormat form
    # ("CZ Dabing" -> "Czech - Dabing"). The language is taken from the title, no Whisper needed.
    [switch]$Normalize,

    # Quick path: when a track has a language tag (e.g. cze) but no language in its title,
    # trust the tag and name the track from it instead of running Whisper.
    [switch]$UseLanguageTag,

    # Replace an existing (non-language) title instead of prefixing it with the language.
    [switch]$ReplaceTitle,

    # Do not descend into subfolders.
    [switch]$NoRecurse,

    # Optional CSV report file.
    [string]$Report,

    # Download / update all tools and the model, then exit.
    [switch]$Setup,

    # CPU threads for Whisper.
    [int]$Threads = [Math]::Min([Environment]::ProcessorCount, 8)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsDir = Join-Path $ScriptDir 'tools'
$VideoExtensions = @('.mkv', '.webm', '.mka', '.mp4', '.m4v', '.mov', '.avi', '.ts', '.m2ts', '.mts', '.mpg', '.mpeg', '.vob', '.wmv', '.flv', '.ogm', '.3gp')
$MkvExtensions = @('.mkv', '.webm', '.mka')
$Mp4Extensions = @('.mp4', '.m4v', '.mov', '.3gp')

# ---------------------------------------------------------------------------------------------
#  Language table: whisper code | English name | ISO 639-2/B | other names/codes found in titles
# ---------------------------------------------------------------------------------------------
$LanguageData = @'
en|English|eng|anglicky,anglický,angličtina,anglictina,inglés,ingles,englisch,anglais,inglese,angielski
zh|Chinese|chi|zho,mandarin,中文,普通话,普通話,國語,国语,汉语,漢語,华语,chinesisch,chinois,čínština
de|German|ger|deu,deutsch,německy,nemecky,němčina,nemcina,alemán,aleman,allemand,tedesco,niemiecki
es|Spanish|spa|español,espanol,castellano,castilian,latino,španělsky,spanelsky,španělština,spanisch,espagnol
ru|Russian|rus|русский,rusky,ruština,rustina,russisch,russe,ruso,rosyjski
ko|Korean|kor|한국어,korejsky,korejština,koreanisch,coréen,coreano
fr|French|fre|fra,français,francais,francouzsky,francouzština,francouzstina,französisch,franzosisch,francés,frances
ja|Japanese|jpn|日本語,japonsky,japonština,japonstina,japanisch,japonais,japonés,giapponese
pt|Portuguese|por|português,portugues,brazilian,portugalsky,portugalština,portugiesisch,portugais
tr|Turkish|tur|türkçe,turkce,turecky,turečtina,türkisch,turc,turco
pl|Polish|pol|polski,polsky,polština,polstina,polnisch,polonais,polaco
ca|Catalan|cat|català,catala,katalánsky
nl|Dutch|dut|nld,nederlands,flemish,vlaams,nizozemsky,niederländisch,néerlandais,holandés
ar|Arabic|ara|العربية,arabsky,arabisch,arabe
sv|Swedish|swe|svenska,švédsky,svedsky,schwedisch,suédois,sueco
it|Italian|ita|italiano,italsky,italština,italstina,italienisch,italien
id|Indonesian|ind|bahasa,indonésky
hi|Hindi|hin|हिन्दी,हिंदी
fi|Finnish|fin|suomi,finsky,finnisch,finnois
vi|Vietnamese|vie|tiếng,vietnamsky
he|Hebrew|heb|עברית,hebrejsky,ivrit
uk|Ukrainian|ukr|українська,ukrajinsky,ukrajinština,ukrainisch,ukrainien
el|Greek|gre|ell,ελληνικά,řecky,recky,griechisch,grec,griego
ms|Malay|may|msa,melayu
cs|Czech|cze|ces,čeština,cestina,česky,cesky,český,cesky,tschechisch,tchèque,checo,ceco,czeski
ro|Romanian|rum|ron,română,romana,rumunsky,rumänisch
da|Danish|dan|dansk,dánsky,dansky,dänisch,danois
hu|Hungarian|hun|magyar,maďarsky,madarsky,ungarisch,hongrois
ta|Tamil|tam|தமிழ்
no|Norwegian|nor|nob,norsk,bokmål,bokmal,norsky,norwegisch,norvégien
th|Thai|tha|ไทย,thajsky
ur|Urdu|urd|اردو
hr|Croatian|hrv|hrvatski,chorvatsky,kroatisch
bg|Bulgarian|bul|български,bulharsky,bulgarisch
lt|Lithuanian|lit|lietuvių,lietuviu,litevsky
la|Latin|lat|latina,latinsky
mi|Maori|mao|mri,māori,reo
ml|Malayalam|mal|മലയാളം
cy|Welsh|wel|cym,cymraeg
sk|Slovak|slo|slk,slovenčina,slovencina,slovensky,slovenský,slowakisch
te|Telugu|tel|తెలుగు
fa|Persian|per|fas,farsi,فارسی
lv|Latvian|lav|latviešu,latviesu,lotyšsky
bn|Bengali|ben|bangla,বাংলা
sr|Serbian|srp|srpski,српски,srbsky,serbisch
az|Azerbaijani|aze|azərbaycan,azeri
sl|Slovenian|slv|slovene,slovenščina,slovenscina,slovinsky
kn|Kannada|kan|ಕನ್ನಡ
et|Estonian|est|eesti,estonsky
mk|Macedonian|mac|mkd,македонски
br|Breton|bre|brezhoneg
eu|Basque|baq|eus,euskara
is|Icelandic|ice|isl,íslenska,islenska,islandsky
hy|Armenian|arm|hye,հայերեն
ne|Nepali|nep|नेपाली
mn|Mongolian|mon|монгол
bs|Bosnian|bos|bosanski
kk|Kazakh|kaz|қазақ
sq|Albanian|alb|sqi,shqip
sw|Swahili|swa|kiswahili
gl|Galician|glg|galego
mr|Marathi|mar|मराठी
pa|Punjabi|pan|panjabi,ਪੰਜਾਬੀ
si|Sinhala|sin|sinhalese,සිංහල
km|Khmer|khm|ខ្មែរ
sn|Shona|sna|chishona
yo|Yoruba|yor|yorùbá
so|Somali|som|soomaali
af|Afrikaans|afr|
oc|Occitan|oci|
ka|Georgian|geo|kat,ქართული
be|Belarusian|bel|беларуская
tg|Tajik|tgk|тоҷикӣ
sd|Sindhi|snd|
gu|Gujarati|guj|ગુજરાતી
am|Amharic|amh|አማርኛ
yi|Yiddish|yid|ייִדיש
lo|Lao|lao|ລາວ
uz|Uzbek|uzb|oʻzbek
fo|Faroese|fao|føroyskt
ht|Haitian Creole|hat|haitian,kreyòl
ps|Pashto|pus|پښتو
tk|Turkmen|tuk|türkmen
nn|Nynorsk|nno|
mt|Maltese|mlt|malti
sa|Sanskrit|san|संस्कृतम्
lb|Luxembourgish|ltz|lëtzebuergesch
my|Burmese|bur|mya,myanmar
bo|Tibetan|tib|bod
tl|Tagalog|tgl|filipino,fil
mg|Malagasy|mlg|
as|Assamese|asm|
tt|Tatar|tat|татар
haw|Hawaiian|haw|
ln|Lingala|lin|
ha|Hausa|hau|
ba|Bashkir|bak|
jw|Javanese|jav|
su|Sundanese|sun|
yue|Cantonese|chi|粵語,粤语,廣東話,广东话
'@

# 3-letter codes that are also common words - only recognized in UPPERCASE in titles.
$AmbiguousCodes = @('may', 'per', 'mar', 'pan', 'sun', 'san', 'mon', 'bel', 'est', 'lit', 'tam', 'tel', 'dan', 'bur',
    'ice', 'arm', 'lat', 'hat', 'sin', 'mal', 'tat', 'haw', 'cat', 'por', 'som', 'wel', 'bos', 'ind', 'ben', 'kan',
    'lin', 'bak', 'vie', 'rum', 'mac', 'fin', 'nor', 'reo', 'fil', 'lao', 'geo', 'tib', 'bod', 'hin', 'ell', 'ron')
# Extra uppercase-only tokens commonly used for languages in release titles -> whisper code.
$ExtraUpperTokens = @{ CZ = 'cs'; SK = 'sk'; JP = 'ja'; JAP = 'ja'; KR = 'ko'; CN = 'zh'; UA = 'uk'; DK = 'da'; GR = 'el'
    BR = 'pt'; SE = 'sv'; SI = 'sl'; RS = 'sr'; PT = 'pt'; BRA = 'pt'; LAT = 'es'; CAST = 'es' }
# Extra language-tag codes (ISO 639 / IETF primary subtags) -> whisper code.
$ExtraTagCodes = @{ nob = 'no'; nb = 'no'; cmn = 'zh'; jv = 'jw'; fil = 'tl'; scc = 'sr'; scr = 'hr'; iw = 'he'; in = 'id' }

$Languages = @{}                                                                              # whisper code -> object
$TokensCI = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
$TokensUpper = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
$TokenSubstrings = New-Object 'System.Collections.Generic.Dictionary[string,string]'      # CJK etc. (no word boundaries)
$TagCodes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)

function Add-Token($dict, [string]$key, [string]$code) { if (-not $dict.ContainsKey($key)) { $dict[$key] = $code } }

foreach ($line in ($LanguageData -split "`r?`n")) {
    if (-not $line.Trim()) { continue }
    $f = $line.Split('|')
    $code = $f[0]; $name = $f[1]; $iso = $f[2]
    $aliases = @()
    if ($f.Count -gt 3 -and $f[3]) { $aliases = $f[3].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    $Languages[$code] = [pscustomobject]@{ Code = $code; Name = $name; Iso = $iso }

    foreach ($w in $name.Split(' ')) { Add-Token $TokensCI $w $code }
    Add-Token $TagCodes $code $code
    foreach ($tok in @($iso) + $aliases) {
        if ($tok -match '^[a-z]{3}$') {
            Add-Token $TagCodes $tok $code
            if ($AmbiguousCodes -contains $tok) { Add-Token $TokensUpper $tok.ToUpperInvariant() $code }
            else { Add-Token $TokensCI $tok $code }
        }
        elseif ($tok -match '[\p{IsCJKUnifiedIdeographs}\p{IsHiragana}\p{IsKatakana}\p{IsHangulSyllables}\p{IsThai}]') {
            Add-Token $TokenSubstrings $tok $code
        }
        else { Add-Token $TokensCI $tok $code }
    }
    if ($code.Length -eq 2) { Add-Token $TokensUpper $code.ToUpperInvariant() $code }
}
foreach ($k in $ExtraUpperTokens.Keys) { Add-Token $TokensUpper $k $ExtraUpperTokens[$k] }
foreach ($k in $ExtraTagCodes.Keys) { Add-Token $TagCodes $k $ExtraTagCodes[$k] }

# Finds language mentions in a title. Returns objects { Code; Index; Length }.
function Get-TitleLanguages([string]$Title) {
    $found = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Title)) { return , $found }
    foreach ($s in $TokenSubstrings.Keys) {
        $i = $Title.IndexOf($s)
        if ($i -ge 0) { $found.Add([pscustomobject]@{ Code = $TokenSubstrings[$s]; Index = $i; Length = $s.Length }) }
    }
    foreach ($m in [regex]::Matches($Title, '[\p{L}\p{M}]+')) {
        $c = $null
        if ($TokensCI.ContainsKey($m.Value)) { $c = $TokensCI[$m.Value] }
        elseif ($TokensUpper.ContainsKey($m.Value)) { $c = $TokensUpper[$m.Value] }
        if ($c) { $found.Add([pscustomobject]@{ Code = $c; Index = $m.Index; Length = $m.Length }) }
    }
    return , $found
}

function Test-TitleHasLanguage([string]$Title) { return (Get-TitleLanguages $Title).Count -gt 0 }

# Maps a container language tag (cze, ces, cs, cs-CZ, ...) to a whisper code; $null for und/unknown.
function Resolve-TagLanguage([string]$Tag) {
    if ([string]::IsNullOrWhiteSpace($Tag)) { return $null }
    $primary = ($Tag.Trim() -split '[-_]')[0]
    if ($primary -match '^(und|mul|zxx|mis|qaa)$') { return $null }
    if ($TagCodes.ContainsKey($primary)) { return $TagCodes[$primary] }
    return $null
}

# Title text without the language words, e.g. "CZ - Dabing [DTS]" -> "Dabing [DTS]".
function Get-TitleRemainder([string]$Title, $Found) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return '' }
    $s = $Title
    foreach ($m in ($Found | Sort-Object Index -Descending)) { $s = $s.Remove($m.Index, $m.Length) }
    do {
        $prev = $s
        $s = $s -replace '\[\s*[-_/|,.]*\s*\]|\(\s*[-_/|,.]*\s*\)|\{\s*\}', ' '
        $s = $s -replace '\s*[/|+&,]\s*(?=[/|+&,]|$)', '' -replace '^\s*[/|+&,]\s*', ''
        $s = ($s -replace '\s{2,}', ' ').Trim(" `t-_:.|/,".ToCharArray())
    } while ($s -ne $prev)
    return $s
}

function Get-LanguageLabel($Lang) {
    switch ($NameFormat) {
        'Iso'      { return $Lang.Iso }
        'IsoUpper' { return $Lang.Iso.ToUpperInvariant() }
        default    { return $Lang.Name }
    }
}

function Format-TrackTitle($Lang, [string]$Remainder) {
    $label = Get-LanguageLabel $Lang
    if ($Remainder -and -not $ReplaceTitle) { return "$label - $Remainder" }
    return $label
}

# ---------------------------------------------------------------------------------------------
#  Process helpers
# ---------------------------------------------------------------------------------------------
function ConvertTo-ArgString([string]$a) {
    if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"'); $bs = 0
    foreach ($c in $a.ToCharArray()) {
        if ($c -eq '\') { $bs++; continue }
        if ($c -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)).Append('"') }
        else { [void]$sb.Append('\' * $bs).Append($c) }
        $bs = 0
    }
    [void]$sb.Append('\' * ($bs * 2)).Append('"')
    return $sb.ToString()
}

function Invoke-Tool([string]$Exe, [string[]]$Arguments, [string]$WorkDir) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-ArgString $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

# ---------------------------------------------------------------------------------------------
#  Tool installation (portable, into .\tools)
# ---------------------------------------------------------------------------------------------
$Ffmpeg = Join-Path $ToolsDir 'ffmpeg\ffmpeg.exe'
$Ffprobe = Join-Path $ToolsDir 'ffmpeg\ffprobe.exe'
$WhisperCli = Join-Path $ToolsDir 'whisper\whisper-cli.exe'
$WhisperVkCli = Join-Path $ToolsDir 'whisper-vulkan\whisper-cli.exe'
$DeviceCacheFile = Join-Path $ToolsDir 'device-cache.json'
# Pinned, tested combination. whisper.cpp ships no Vulkan build for Windows, so the GPU variant is
# whisper-cli + the ggml backend DLLs (incl. ggml-vulkan.dll) from the matching llama.cpp release.
$WhisperRelease = 'b5454'
$LlamaRelease = 'b12211'
$MkvPropEdit = Join-Path $ToolsDir 'mkvtoolnix\mkvpropedit.exe'
$ModelFile = Join-Path $ToolsDir "models\ggml-$Model.bin"
$VadModelFile = Join-Path $ToolsDir 'models\ggml-silero-v5.1.2.bin'
$VerifyModelFile = if ($VerifyModel) { Join-Path $ToolsDir "models\ggml-$VerifyModel.bin" } else { $null }
if ($VerifyModel -eq $Model) { $VerifyModel = '' }

function Save-Download([string]$Url, [string]$Dest) {
    New-Item -ItemType Directory -Force (Split-Path $Dest) | Out-Null
    $part = "$Dest.part"
    Write-Host "  downloading $Url" -ForegroundColor DarkGray
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        & $curl -L --fail --retry 3 --progress-bar -o $part $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed ($LASTEXITCODE): $Url" }
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
    }
    Move-Item -Force $part $Dest
}

function Expand-ZipEntries([string]$Zip, [string]$DestDir, [scriptblock]$Filter) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force $DestDir | Out-Null
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $n = 0
        foreach ($e in $z.Entries) {
            if (-not $e.Name) { continue }
            if (& $Filter $e.FullName) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $DestDir $e.Name), $true)
                $n++
            }
        }
        if ($n -eq 0) { throw "Nothing matching found in $Zip" }
    }
    finally { $z.Dispose() }
}

function Install-Tools([switch]$Update) {
    $dl = Join-Path $ToolsDir '_download'
    New-Item -ItemType Directory -Force $dl | Out-Null
    try {
        if ($Update -or -not (Test-Path $Ffmpeg) -or -not (Test-Path $Ffprobe)) {
            Write-Host 'Installing ffmpeg ...' -ForegroundColor Cyan
            $zip = Join-Path $dl 'ffmpeg.zip'
            Save-Download 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' $zip
            Expand-ZipEntries $zip (Split-Path $Ffmpeg) { param($n) $n -match '/bin/(ffmpeg|ffprobe)\.exe$' }
        }
        if ($Update -or -not (Test-Path $WhisperCli)) {
            Write-Host "Installing whisper.cpp $WhisperRelease ..." -ForegroundColor Cyan
            $zip = Join-Path $dl 'whisper.zip'
            Save-Download "https://github.com/ggml-org/whisper.cpp/releases/download/$WhisperRelease/whisper-bin-x64.zip" $zip
            Expand-ZipEntries $zip (Split-Path $WhisperCli) { param($n) $n -match '(whisper-cli\.exe|\.dll)$' }
        }
        if ($Update -or -not (Test-Path $WhisperVkCli)) {
            Write-Host "Installing GPU (Vulkan) backend from llama.cpp $LlamaRelease ..." -ForegroundColor Cyan
            try {
                $vkDir = Split-Path $WhisperVkCli
                $zip = Join-Path $dl 'llama-vulkan.zip'
                Save-Download "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaRelease/llama-$LlamaRelease-bin-win-vulkan-x64.zip" $zip
                New-Item -ItemType Directory -Force $vkDir | Out-Null
                Copy-Item (Join-Path (Split-Path $WhisperCli) '*') $vkDir -Exclude 'whisper-cli.exe' -Force
                Expand-ZipEntries $zip $vkDir { param($n) $n -match '(^|/)(ggml[^/]*|libomp[^/]*)\.dll$' }
                Copy-Item $WhisperCli $vkDir -Force     # last, so a half-finished install is not mistaken for a complete one
                Remove-Item $DeviceCacheFile -ErrorAction SilentlyContinue
            }
            catch { Write-Warning "GPU backend could not be installed ($($_.Exception.Message)); using CPU only." }
        }
        if ($Update -or -not (Test-Path $MkvPropEdit)) {
            Write-Host 'Installing mkvpropedit (MKVToolNix) ...' -ForegroundColor Cyan
            try {
                [xml]$x = (Invoke-WebRequest -UseBasicParsing 'https://mkvtoolnix.download/latest-release.xml').Content
                $v = $x.'mkvtoolnix-releases'.'latest-source'.version
                $zip = Join-Path $dl 'mkvtoolnix.zip'
                Save-Download "https://mkvtoolnix.download/windows/releases/$v/mkvtoolnix-64-bit-$v.zip" $zip
                Expand-ZipEntries $zip (Split-Path $MkvPropEdit) { param($n) $n -match '/mkvpropedit\.exe$' }
            }
            catch { Write-Warning "mkvpropedit could not be installed ($($_.Exception.Message)); MKV files will be remuxed with ffmpeg instead." }
        }
        if (-not (Test-Path $ModelFile)) {
            Write-Host "Downloading Whisper model '$Model' ..." -ForegroundColor Cyan
            Save-Download "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$Model.bin" $ModelFile
        }
        if ($VerifyModel -and -not (Test-Path $VerifyModelFile)) {
            Write-Host "Downloading verification model '$VerifyModel' ..." -ForegroundColor Cyan
            Save-Download "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$VerifyModel.bin" $VerifyModelFile
        }
        if (-not (Test-Path $VadModelFile)) {
            Write-Host 'Downloading Silero VAD model ...' -ForegroundColor Cyan
            Save-Download 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin' $VadModelFile
        }
    }
    finally { Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------------
#  Probing / sampling / detection
# ---------------------------------------------------------------------------------------------
function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($p) { return $p.Value } else { return $null }
}

function ConvertFrom-Duration($v) {
    if ($null -eq $v) { return 0.0 }
    $s = "$v"
    if ($s -match '^(\d+):(\d+):(\d+(?:\.\d+)?)$') {
        return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture)
    }
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return 0.0
}

function Get-AudioTracks([string]$File) {
    $r = Invoke-Tool $Ffprobe @('-v', 'error', '-select_streams', 'a', '-show_entries',
        'format=duration:stream=index,codec_name,channels,duration:stream_tags', '-of', 'json', $File)
    if ($r.ExitCode -ne 0) { throw "ffprobe failed: $($r.Err.Trim())" }
    $j = $r.Out | ConvertFrom-Json
    $fmtDur = ConvertFrom-Duration (Get-Prop (Get-Prop $j 'format') 'duration')
    $i = 0
    foreach ($s in @(Get-Prop $j 'streams')) {
        if ($null -eq $s) { continue }
        $tags = Get-Prop $s 'tags'
        $title = ''; $lang = ''; $handler = ''; $dur = ConvertFrom-Duration (Get-Prop $s 'duration')
        if ($tags) {
            foreach ($p in $tags.PSObject.Properties) {
                if ($p.Name -ieq 'title') { $title = "$($p.Value)" }
                elseif ($p.Name -ieq 'handler_name') { $handler = "$($p.Value)".Trim() }
                elseif ($p.Name -ieq 'language') { $lang = "$($p.Value)" }
                elseif ($p.Name -like 'DURATION*' -and $dur -le 0) { $dur = ConvertFrom-Duration $p.Value }
            }
        }
        if ($dur -le 0) { $dur = $fmtDur }
        # MP4/MOV keep the track name in the handler name; ignore generic muxer defaults
        if (-not $title -and $handler -and $handler -notmatch '(?i)handler|^core media|^mctl$|^\s*$') { $title = $handler }
        [pscustomobject]@{
            AudioIndex = $i; StreamIndex = $s.index; Codec = Get-Prop $s 'codec_name'; Channels = Get-Prop $s 'channels'
            Title = $title; Language = $lang; Duration = $dur
        }
        $i++
    }
}

function Get-SamplePositions([double]$Duration, [int]$Count, [double]$Window) {
    if ($Duration -le 0) { return @(0.0) }
    # skip intro (5 %) and end credits (8 %) when the track is long enough
    $start = $Duration * 0.05
    $end = $Duration * 0.92 - $Window
    if ($end -le $start) { $start = 0.0; $end = [Math]::Max(0.0, $Duration - $Window) }
    if ($end -le 0) { return @(0.0) }
    $seg = ($end - $start) / $Count
    $rnd = New-Object Random
    for ($i = 0; $i -lt $Count; $i++) { $start + $seg * ($i + $rnd.NextDouble()) }
}

function Get-TrackLanguage([string]$File, $Track, [string]$TempDir) {
    $readWindow = $SampleSeconds * 3      # read more, strip silence, keep $SampleSeconds of sound
    $minBytes = 16000 * 2 * 4             # need at least ~4 s of non-silent audio
    $silence = 'silenceremove=stop_periods=-1:stop_duration=0.4:stop_threshold=-42dB'
    $results = New-Object System.Collections.Generic.List[object]
    $allWavs = New-Object System.Collections.Generic.List[string]
    $taken = 0
    $useCenter = ($Track.Channels -as [int]) -ge 3     # surround: dialogue lives in the center channel

    try {
        $maxRounds = 2
        for ($round = 1; $round -le $maxRounds; $round++) {
            $positions = @(Get-SamplePositions $Track.Duration $Samples $readWindow)
            $wavs = New-Object System.Collections.Generic.List[string]
            foreach ($pos in $positions) {
                $taken++
                $wav = "s$taken.wav"
                $ss = $pos.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
                $pre = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
                    '-ss', $ss, '-t', "$readWindow", '-i', $File, '-map', "0:a:$($Track.AudioIndex)", '-vn', '-sn', '-dn')
                $post = @('-t', "$SampleSeconds", '-ar', '16000', '-c:a', 'pcm_s16le', $wav)
                $r = $null
                if ($useCenter) {
                    $r = Invoke-Tool $Ffmpeg ($pre + @('-af', "pan=mono|c0=FC,$silence") + $post) $TempDir
                    if ($r.ExitCode -ne 0) { $useCenter = $false }   # layout without a center channel
                }
                if (-not $useCenter) {
                    $r = Invoke-Tool $Ffmpeg ($pre + @('-af', $silence, '-ac', '1') + $post) $TempDir
                }
                $full = Join-Path $TempDir $wav
                if ($r.ExitCode -eq 0 -and (Test-Path $full) -and (Get-Item $full).Length -ge $minBytes) { $wavs.Add($wav); $allWavs.Add($wav) }
            }
            foreach ($x in (Invoke-LanguageDetect $ModelFile $wavs $TempDir)) { $results.Add($x) }

            $best = Get-VoteResult $results
            if ($best -and $best.Confidence -ge $MinConfidence -and $results.Count -ge $MinSpeechSamples) { break }
            if ($useCenter -and $results.Count -lt $MinSpeechSamples) {
                # center channel silent/empty (fake or odd 5.1) - sample the full mix instead
                Write-Host ' center channel has no speech, using full mix ...' -NoNewline -ForegroundColor DarkGray
                $useCenter = $false
                if ($round -eq $maxRounds) { $maxRounds++ }
                continue
            }
            if ($round -lt $maxRounds) { Write-Host ' unclear, more samples ...' -NoNewline -ForegroundColor DarkGray }
        }

        # Second opinion: re-check the same excerpts with the large model when the fast one is not sure.
        $best = Get-VoteResult $results
        $model = $Model
        if ($VerifyModel -and $best -and $best.Confidence -lt $VerifyBelow) {
            $nm = if ($Languages[$best.Lang]) { $Languages[$best.Lang].Name } else { $best.Lang }
            Write-Host (" {0}? {1:P0}, verifying with {2} ..." -f $nm, $best.Confidence, $VerifyModel) -NoNewline -ForegroundColor DarkGray
            $verified = Invoke-LanguageDetect $VerifyModelFile $allWavs $TempDir
            if ($verified.Count -gt 0) { $results = $verified; $model = $VerifyModel }
        }
    }
    finally { Get-ChildItem -LiteralPath $TempDir -Filter '*.wav' | Remove-Item -Force }

    $best = Get-VoteResult $results
    if ($best -and $results.Count -lt $MinSpeechSamples) { $best.Confidence = 0.0 }   # too little speech to trust
    if (-not $best) { return [pscustomobject]@{ Lang = $null; Confidence = 0.0; Votes = 0; Total = 0; Sampled = $taken; Model = $Model } }
    $best | Add-Member -NotePropertyName Sampled -NotePropertyValue $taken
    $best | Add-Member -NotePropertyName Model -NotePropertyValue $model -PassThru
}

# ---------------------------------------------------------------------------------------------
#  Device selection: CPU vs. each Vulkan GPU, benchmarked once per machine and model, cached
# ---------------------------------------------------------------------------------------------
$script:Runners = @{}
$CpuRunner = [pscustomobject]@{ Exe = $WhisperCli; Args = @(); Label = 'CPU' }

function Get-MachineKey {
    $gpus = ''
    try { $gpus = (Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ',' } catch {}
    return "$env:COMPUTERNAME|$gpus"
}

function Measure-Runner([string]$Exe, [string[]]$ExtraArgs, [string]$ModelPath, [string]$WorkDir) {
    $wargs = @('-m', $ModelPath, '-dl', '-l', 'auto', '-t', "$Threads", '-f', 'bench.wav', '-f', 'bench.wav') + $ExtraArgs
    # untimed warm-up: the first start pays one-off costs (antivirus scan of fresh DLLs, GPU shader
    # compilation, cold disk cache) that would otherwise make the first candidate look slow
    [void](Invoke-Tool $Exe $wargs $WorkDir)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Tool $Exe $wargs $WorkDir
    $sec = $sw.Elapsed.TotalSeconds
    $text = $r.Err + "`n" + $r.Out
    $ok = $r.ExitCode -eq 0 -and ([regex]::Matches($text, 'auto-detected language:')).Count -eq 2
    [pscustomobject]@{ Ok = $ok; Seconds = $sec; Text = $text }
}

function Get-WhisperRunner([string]$ModelPath) {
    if ($script:Runners.ContainsKey($ModelPath)) { return $script:Runners[$ModelPath] }
    $runner = $CpuRunner
    if ($Device -ne 'Cpu' -and (Test-Path $WhisperVkCli)) {
        # 'v2': benchmarks with warm-up; results cached by older versions are ignored and re-measured
        $key = 'v2|' + (Get-MachineKey) + '|' + (Split-Path $ModelPath -Leaf)
        $cache = @{}
        try {
            if (Test-Path $DeviceCacheFile) {
                $j = Get-Content -Raw -LiteralPath $DeviceCacheFile | ConvertFrom-Json
                foreach ($p in $j.PSObject.Properties) { $cache[$p.Name] = $p.Value }
            }
        } catch {}
        $hit = if ($Device -eq 'Auto') { $cache[$key] } else { $null }
        if ($hit) {
            if ($hit.Kind -eq 'vulkan') { $runner = [pscustomobject]@{ Exe = $WhisperVkCli; Args = @('-dev', "$($hit.Dev)"); Label = $hit.Label } }
        }
        else {
            Write-Host "  Benchmarking CPU/GPU for $(Split-Path $ModelPath -Leaf) (one-time on this machine) ..." -ForegroundColor DarkGray
            $r = Invoke-Tool $Ffmpeg @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
                'anoisesrc=color=pink:amplitude=0.1:duration=30', '-ar', '16000', '-ac', '1', 'bench.wav') $TempDir
            $results = @()
            if ($Device -eq 'Auto') {
                $m = Measure-Runner $WhisperCli @() $ModelPath $TempDir
                if ($m.Ok) { $results += [pscustomobject]@{ Kind = 'cpu'; Dev = -1; Label = 'CPU'; Seconds = $m.Seconds } }
            }
            # discover Vulkan devices with a first run on device 0
            $m = Measure-Runner $WhisperVkCli @('-dev', '0') $ModelPath $TempDir
            $names = @{}
            foreach ($x in [regex]::Matches($m.Text, 'ggml_vulkan:\s*(\d+)\s*=\s*([^|\r\n]+?)\s*(\(|\|)')) { $names[[int]$x.Groups[1].Value] = $x.Groups[2].Value.Trim() }
            for ($i = 0; $i -lt [Math]::Max(1, $names.Count); $i++) {
                if ($i -gt 0) { $m = Measure-Runner $WhisperVkCli @('-dev', "$i") $ModelPath $TempDir }
                if ($m.Ok -and $m.Text -match "using Vulkan$i backend") {
                    $label = if ($names[$i]) { "$($names[$i]) (Vulkan)" } else { "Vulkan$i" }
                    $results += [pscustomobject]@{ Kind = 'vulkan'; Dev = $i; Label = $label; Seconds = $m.Seconds }
                }
            }
            Remove-Item -LiteralPath (Join-Path $TempDir 'bench.wav') -ErrorAction SilentlyContinue
            $summary = ($results | ForEach-Object { '{0} {1:N1}s' -f $_.Label, $_.Seconds }) -join ', '
            if (-not $summary) { $summary = 'no GPU usable' }
            $best = $results | Sort-Object Seconds | Select-Object -First 1
            if ($best -and $best.Kind -eq 'vulkan') {
                $runner = [pscustomobject]@{ Exe = $WhisperVkCli; Args = @('-dev', "$($best.Dev)"); Label = $best.Label }
            }
            Write-Host "  -> using $($runner.Label)  [$summary]" -ForegroundColor DarkGray
            if ($Device -eq 'Auto' -and $best) {
                $cache[$key] = [pscustomobject]@{ Kind = $best.Kind; Dev = $best.Dev; Label = $best.Label; Benchmark = $summary }
                try { ([pscustomobject]$cache) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $DeviceCacheFile -Encoding UTF8 } catch {}
            }
        }
    }
    $script:Runners[$ModelPath] = $runner
    return $runner
}

# Runs whisper language detection on excerpts (relative names inside $WorkDir). Returns { Lang; P } per excerpt with speech.
function Invoke-LanguageDetect([string]$ModelPath, $Wavs, [string]$WorkDir) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Wavs -or @($Wavs).Count -eq 0) { return , $out }
    # VAD: excerpts without speech (music, effects, noise) yield no detection instead of a bogus language
    $wargs = @('-m', $ModelPath, '-dl', '-l', 'auto', '-t', "$Threads", '--vad', '--vad-model', $VadModelFile)
    foreach ($w in $Wavs) { $wargs += @('-f', $w) }
    $runner = Get-WhisperRunner $ModelPath
    $r = Invoke-Tool $runner.Exe ($wargs + $runner.Args) $WorkDir
    if ($runner.Exe -ne $WhisperCli -and ($r.ExitCode -ne 0 -or $r.Err -notmatch 'auto-detected language|speech segments')) {
        # GPU run failed (driver issue etc.) - fall back to CPU for the rest of this session
        Write-Host " (GPU failed, falling back to CPU)" -NoNewline -ForegroundColor Yellow
        $script:Runners[$ModelPath] = $CpuRunner
        $r = Invoke-Tool $WhisperCli $wargs $WorkDir
    }
    foreach ($m in [regex]::Matches($r.Err + "`n" + $r.Out, 'auto-detected language:\s*(\w+)\s*\(p\s*=\s*([\d.]+)\)')) {
        $out.Add([pscustomobject]@{ Lang = $m.Groups[1].Value; P = [double]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture) })
    }
    if ($out.Count -eq 0 -and $r.ExitCode -ne 0) { throw "whisper-cli failed: $(($r.Err -split "`n" | Select-Object -Last 3) -join ' ')" }
    return , $out
}

function Get-VoteResult($results) {
    if (-not $results -or $results.Count -eq 0) { return $null }
    $g = $results | Group-Object Lang | ForEach-Object {
        [pscustomobject]@{ Lang = $_.Name; Score = ($_.Group | Measure-Object P -Sum).Sum; Votes = $_.Count }
    } | Sort-Object Score -Descending | Select-Object -First 1
    [pscustomobject]@{ Lang = $g.Lang; Confidence = $g.Score / $results.Count; Votes = $g.Votes; Total = $results.Count }
}

# ---------------------------------------------------------------------------------------------
#  Writing results
# ---------------------------------------------------------------------------------------------
function Set-TracksMkv([string]$File, $Changes) {
    $a = @($File)
    foreach ($c in $Changes) {
        $a += @('--edit', "track:a$($c.AudioIndex + 1)", '--set', "language=$($c.Iso)", '--set', "name=$($c.NewTitle)")
    }
    $r = Invoke-Tool $MkvPropEdit $a
    if ($r.ExitCode -ge 2) { throw "mkvpropedit failed: $(($r.Out + $r.Err).Trim())" }
}

function Set-TracksRemux([string]$File, $Changes, [int]$AudioCount) {
    $ext = [IO.Path]::GetExtension($File)
    $tmp = [IO.Path]::Combine([IO.Path]::GetDirectoryName($File), [IO.Path]::GetFileNameWithoutExtension($File) + '.atid-tmp' + $ext)
    $meta = @()
    foreach ($c in $Changes) {
        $meta += @("-metadata:s:a:$($c.AudioIndex)", "language=$($c.Iso)", "-metadata:s:a:$($c.AudioIndex)", "title=$($c.NewTitle)")
        if ($Mp4Extensions -contains $ext.ToLowerInvariant()) { $meta += @("-metadata:s:a:$($c.AudioIndex)", "handler_name=$($c.NewTitle)") }
    }
    $base = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-i', $File)
    $tail = @('-c', 'copy', '-map_metadata', '0', '-map_chapters', '0') + $meta + @($tmp)
    $r = Invoke-Tool $Ffmpeg ($base + @('-map', '0') + $tail)
    if ($r.ExitCode -ne 0) {
        # some containers refuse to copy data/attachment streams - retry with the main stream types only
        $r = Invoke-Tool $Ffmpeg ($base + @('-map', '0:v?', '-map', '0:a', '-map', '0:s?') + $tail)
    }
    try {
        if ($r.ExitCode -ne 0) { throw "ffmpeg remux failed: $($r.Err.Trim())" }
        $chk = @(Get-AudioTracks $tmp)
        if ($chk.Count -ne $AudioCount) { throw "remux verification failed (audio tracks $($chk.Count) != $AudioCount)" }
        $srcLen = (Get-Item -LiteralPath $File).Length
        if ((Get-Item -LiteralPath $tmp).Length -lt $srcLen * 0.9) { throw 'remux verification failed (output much smaller than source)' }
        $orig = Get-Item -LiteralPath $File
        $bak = "$File.atid-bak"
        Move-Item -LiteralPath $File -Destination $bak -Force
        try { Move-Item -LiteralPath $tmp -Destination $File -Force }
        catch { Move-Item -LiteralPath $bak -Destination $File -Force; throw }
        (Get-Item -LiteralPath $File).LastWriteTime = $orig.LastWriteTime
        Remove-Item -LiteralPath $bak -Force
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

# ---------------------------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------------------------
# Keep the console window open at the end only when started from Explorer (double-click /
# drag & drop / Send to) - detected as: this process <- cmd.exe launcher <- explorer.exe.
$PauseAtEnd = $false
if ($env:ATID_LAUNCHER) {
    try {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
        $cmd = Get-CimInstance Win32_Process -Filter "ProcessId=$($parent.ParentProcessId)"
        $grand = Get-Process -Id $cmd.ParentProcessId -ErrorAction Stop
        $PauseAtEnd = $grand.ProcessName -eq 'explorer'
    } catch {}
}

try {
if ($Model -like '*.en') { throw "Model '$Model' is English-only; use a multilingual model (tiny, base, small, medium, large-v3, large-v3-turbo)." }

if ($Setup) {
    Install-Tools -Update
    Write-Host "Tools ready in $ToolsDir" -ForegroundColor Green
    return
}

if (-not $Path -or $Path.Count -eq 0) {
    Write-Host 'Usage: AudiotrackID <folder|file> [...] [-DryRun] [-NameFormat Name|Iso|IsoUpper] [-Normalize] [-UseLanguageTag]'
    Write-Host '                    [-Model small] [-Samples 6] [-MinConfidence 0.6] [-Force] [-ReplaceTitle] [-NoRecurse] [-Report out.csv]'
    Write-Host '       AudiotrackID -Setup     (download all tools for offline use)'
    exit 1
}

Install-Tools
$HaveMkvPropEdit = Test-Path $MkvPropEdit
$MinSpeechSamples = [Math]::Min(2, $Samples)

Write-Host 'Searching for video files ...' -ForegroundColor Cyan
$files = New-Object System.Collections.Generic.List[string]
foreach ($p in $Path) {
    if (Test-Path -LiteralPath $p -PathType Container) {
        $gci = @{ LiteralPath = $p; File = $true; Recurse = (-not $NoRecurse) }
        Get-ChildItem @gci | Where-Object { $VideoExtensions -contains $_.Extension.ToLowerInvariant() -and $_.Name -notmatch '\.atid-(tmp|bak)' } |
            Sort-Object FullName | ForEach-Object { $files.Add($_.FullName) }
    }
    elseif (Test-Path -LiteralPath $p -PathType Leaf) { $files.Add((Resolve-Path -LiteralPath $p).ProviderPath) }
    else { Write-Warning "Not found: $p" }
}
if ($files.Count -eq 0) { Write-Host 'No video files found.'; exit 0 }

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ('AudiotrackID-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TempDir | Out-Null
$rows = New-Object System.Collections.Generic.List[object]
$mode = if ($DryRun) { ' (dry run)' } else { '' }

# pick CPU/GPU up front (benchmark output would otherwise interrupt a track's line)
try {
    $rm = Get-WhisperRunner $ModelFile
    $msg = "Whisper device: $($rm.Label) ($Model)"
    if ($VerifyModel) { $rv = Get-WhisperRunner $VerifyModelFile; $msg += ", $($rv.Label) ($VerifyModel)" }
    Write-Host $msg -ForegroundColor Cyan
}
catch { Write-Warning "Device selection failed ($($_.Exception.Message)); using CPU." }
Write-Host "Found $($files.Count) video file(s)." -ForegroundColor Cyan

# Offer the quick path (trust existing language tags) the first time it applies, unless decided on the command line.
$script:AskTagQuickPath = -not $Force -and -not $PSBoundParameters.ContainsKey('UseLanguageTag')
if ($script:AskTagQuickPath) {
    try { if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { $script:AskTagQuickPath = $false } } catch { $script:AskTagQuickPath = $false }
}
function Confirm-TagQuickPath([string]$Track, [string]$Tag) {
    if (-not $script:AskTagQuickPath) { return }
    $script:AskTagQuickPath = $false
    Write-Host "   $Track has no language in its title but carries the language tag '$Tag'." -ForegroundColor Yellow
    $answer = Read-Host '   Quick path for this and all following such tracks: name them from the tag instead of running Whisper? [y/N]'
    if ($answer -match '^\s*(y|yes|a|ano)\s*$') { $script:UseLanguageTag = [switch]$true }
}

$how = @("names: $NameFormat")
if ($Normalize) { $how += 'normalize named tracks' }
if ($UseLanguageTag) { $how += 'trust language tags' }
if ($Force) { $how += 'Whisper on all tracks' }
Write-Host "Model: $Model, $Samples x ${SampleSeconds}s samples per track; $($how -join ', ')$mode" -ForegroundColor Cyan

function New-Row($file, $t) {
    [pscustomobject]@{ File = $file; Track = "a$($t.AudioIndex + 1)"; OldTitle = $t.Title; OldLanguage = $t.Language
        Source = ''; Detected = ''; Confidence = ''; Votes = ''; NewTitle = ''; Status = '' }
}

# --- pass 2: identify and rename ------------------------------------------------------------------
try {
    $n = 0
    foreach ($file in $files) {
        $n++
        Write-Host ''
        Write-Host "[$n/$($files.Count)] $file" -ForegroundColor White
        try {
            $tracks = @(Get-AudioTracks $file)
            if ($tracks.Count -eq 0) { Write-Host '   no audio tracks' -ForegroundColor DarkGray; continue }
            $changes = New-Object System.Collections.Generic.List[object]

            foreach ($t in $tracks) {
                $desc = "a$($t.AudioIndex + 1) [$($t.Codec) $($t.Channels)ch, lang=$(if ($t.Language) { $t.Language } else { '-' })]"
                $shown = if ($t.Title) { "'$($t.Title)'" } else { '(no title)' }
                $found = Get-TitleLanguages $t.Title
                $titleCodes = @($found | ForEach-Object { $_.Code } | Select-Object -Unique)
                $tagCode = Resolve-TagLanguage $t.Language
                $row = New-Row $file $t

                # decide where the language comes from
                $source = 'whisper'; $code = $null
                if (-not $Force -and $titleCodes.Count -gt 0) {
                    if (-not $Normalize) {
                        Write-Host "   $desc $shown - already named, skipped" -ForegroundColor DarkGray
                        continue
                    }
                    if ($titleCodes.Count -gt 1) {
                        Write-Host "   $desc $shown - several languages in title, left unchanged" -ForegroundColor Yellow
                        $row.Status = 'ambiguous title'; $rows.Add($row); continue
                    }
                    $source = 'title'; $code = $titleCodes[0]
                }
                elseif (-not $Force -and $tagCode) {
                    if (-not $UseLanguageTag) { Confirm-TagQuickPath "$desc $shown" $t.Language }
                    if ($UseLanguageTag) { $source = 'tag'; $code = $tagCode }
                }
                $row.Source = $source

                if ($source -eq 'whisper') {
                    Write-Host "   $desc $shown - detecting ..." -NoNewline
                    $res = Get-TrackLanguage $file $t $TempDir
                    $row.Detected = $res.Lang; $row.Confidence = [Math]::Round($res.Confidence, 3); $row.Votes = "$($res.Votes)/$($res.Total)"
                    if (-not $res.Lang) {
                        Write-Host ' no speech found' -ForegroundColor Yellow
                        $row.Status = 'no speech'; $rows.Add($row); continue
                    }
                    $code = $res.Lang
                    $pct = '{0:P0}' -f $res.Confidence
                    $langName = if ($Languages[$code]) { $Languages[$code].Name } else { $code }
                    if ($res.Confidence -lt $MinConfidence) {
                        Write-Host " $langName? $pct ($($res.Votes)/$($res.Total)) - too uncertain, left unchanged" -ForegroundColor Yellow
                        $row.Status = 'uncertain'; $rows.Add($row); continue
                    }
                    $via = if ($res.Model -ne $Model) { ", $($res.Model)" } else { '' }
                    Write-Host " $langName $pct ($($res.Votes)/$($res.Total)$via)" -NoNewline -ForegroundColor Green
                }
                else {
                    $row.Detected = $code
                    Write-Host "   $desc $shown - from $source`: $($Languages[$code].Name)" -NoNewline -ForegroundColor Green
                }

                $lang = $Languages[$code]
                if (-not $lang) { $lang = [pscustomobject]@{ Code = $code; Name = $code; Iso = $code } }
                $newTitle = Format-TrackTitle $lang (Get-TitleRemainder $t.Title $found)
                $row.NewTitle = $newTitle
                if ($newTitle -ceq $t.Title -and $tagCode -eq $lang.Code) {
                    Write-Host ' - already correct' -ForegroundColor DarkGray
                    $row.Status = 'unchanged'
                }
                else {
                    Write-Host " -> '$newTitle'" -ForegroundColor Green
                    $row.Status = if ($DryRun) { 'dry run' } else { 'pending' }
                    $changes.Add([pscustomobject]@{ AudioIndex = $t.AudioIndex; Iso = $lang.Iso; NewTitle = $newTitle; Row = $row })
                }
                $rows.Add($row)
            }

            if ($changes.Count -gt 0 -and -not $DryRun) {
                $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
                try {
                    if ($HaveMkvPropEdit -and $MkvExtensions -contains $ext) {
                        Set-TracksMkv $file $changes
                        Write-Host "   updated in place (mkvpropedit)" -ForegroundColor Green
                    }
                    else {
                        Write-Host '   remuxing (stream copy) ...' -NoNewline
                        Set-TracksRemux $file $changes $tracks.Count
                        Write-Host ' done' -ForegroundColor Green
                    }
                    foreach ($c in $changes) { $c.Row.Status = 'renamed' }
                }
                catch {
                    Write-Host ''
                    Write-Host "   FAILED to write: $($_.Exception.Message)" -ForegroundColor Red
                    foreach ($c in $changes) { $c.Row.Status = 'write failed' }
                }
            }
        }
        catch {
            Write-Host "   ERROR: $($_.Exception.Message)" -ForegroundColor Red
            $er = New-Row $file ([pscustomobject]@{ AudioIndex = -1; Title = ''; Language = '' })
            $er.Track = ''; $er.Status = "error: $($_.Exception.Message)"
            $rows.Add($er)
        }
    }
}
finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
if ($rows.Count -gt 0) {
    $rows | Group-Object Status | ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.Name, $_.Count) }
}
else { Write-Host '  nothing to do - all audio tracks already carry a language in their title' }
if ($Report) {
    $rows | Export-Csv -LiteralPath $Report -NoTypeInformation -Encoding UTF8
    Write-Host "Report written to $Report"
}
}
finally {
    if ($PauseAtEnd) { Write-Host ''; [void](Read-Host 'Press Enter to close') }
}
