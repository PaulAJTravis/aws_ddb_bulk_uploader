param(
  [Parameter(Mandatory)][String]$input_file,
  [String]$output_file_basename = 'output.json',
  [String]$environment = 'local'
)

function Get-CSVObjectHeaders {

  param (
    $inputCsv
  )

  $csv_headers = $inputCsv | Get-Member -MemberType "NoteProperty" | Select-Object -ExpandProperty 'Name'
  Write-Host "Getting Headers: $csv_headers"

  return $csv_headers

}

function Create-CSVRow {

  param (
    $inputCsv
  )

  $csv_headers = Get-CSVObjectHeaders -inputCsv $inputCsv
  $csv_row = New-Object PsObject
  foreach ($header in $csv_headers) {
    Add-Member -InputObject $csv_row -MemberType noteproperty -Name $header -Value ""
  }

  Write-Host "Creating OBJ,`nHeaders: $csv_headers`nNew CSV: $csv_row"

  return $csv_row

}

$formatted_csv = Import-CSV -path $input_file 

<#
Put your list of columns in this for loop.
They should be formatted as: "{`"<type specifier>`": `"" + $formatted_csv[$i].columnName + "`" }" 
ALternatively, if you don't need string expansion you can just use single quotes on the outside and skip escaping the doublequotes
#>
for ($i = 0; $i -lt $formatted_csv.length; $i++) {

  $formatted_csv[$i].ani = "{`"S`": `"+" + $formatted_csv[$i].ani + "`" }"
  $formatted_csv[$i].ID = "{`"N`": `"" + $formatted_csv[$i].ID + "`" }"

}

$num_items = $formatted_csv.count

if ($num_items -gt 25) {

  $csv_headers = Get-CSVObjectHeaders -inputCsv $formatted_csv
  $new_csv = Create-CSVRow -inputCsv $formatted_csv

  [System.Collections.ArrayList]$Script:csv_files = @()
  [System.Collections.ArrayList]$Script:csv_object = @()

  for ($i = 0; $i -lt $num_items; $i++) {

    if (($i % 25 -eq 0) -or ($i -eq $num_items - 1)) {
      $csv_files.Add($csv_object) > $null
      $csv_object.clear()
    }

    $row = $null
    $row = Create-CSVRow -inputCsv $formatted_csv

    foreach ($header in $csv_headers) {
      $row.$header = $formatted_csv[$i].$header
    }

    $csv_object.add($row) > $null

  }

  echo $csv_files.count()

}

$formatted_json = ConvertTo-Json -InputObject $formatted_csv

<#
Remove escapes added by ConvertTo-Json
Replace open brace with { "PutRequest": { "Item" : {
And replace close brace with } } },
Only match when the open and close braces are on the same line
#>
$formatted_json = $formatted_json -replace '\\', ''
$formatted_json = $formatted_json -replace '[^"]{', "{`n`"PutRequest`": {`n `"Item`": {"
$formatted_json = $formatted_json -replace '((}[^"])|(},[^"]))', "}`n}`n},`n"
$formatted_json = $formatted_json -replace '"{', '{'
$formatted_json = $formatted_json -replace '}"', '}'

$len = $formatted_json.length - 3

$formatted_json = $formatted_json.remove($len, 1)

$formatted_json = "{`n`"nortek-ofallon-prod-vipTable`": " + $formatted_json + "`n}"

echo $formatted_json > $output_file_basename
