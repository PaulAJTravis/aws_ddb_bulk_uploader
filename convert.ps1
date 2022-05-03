param(
  [Parameter(Mandatory)][String]$input_file, #The CSV file to bulk upload
  [Parameter(Mandatory)][String]$output_file_basename = 'output', #The filename to use for output, script will append numbers and .json to this when no input is provided
  [String]$aws_profile = 'local', #The AWS CLI profile name to use for uploading to, defaults to local for safety
  [Parameter(Mandatory)][String]$tableName = 'local_table' #The name of the DDB table to upload to
)


<#
    Gets the list of headers present in the passed CSV object and returns them in an array.
#>
function Get-CSVObjectHeaders {

  param (
    $inputCsv
  )

  $csv_headers = $inputCsv | Get-Member -MemberType "NoteProperty" | Select-Object -ExpandProperty 'Name'

  return $csv_headers

}

<#
    Creates a custom object with members named after the headers in the passed CSV object.
#>
function Create-CSVRow {

  param (
    $inputCsv
  )

  $csv_headers = Get-CSVObjectHeaders -inputCsv $inputCsv
  $csv_row = New-Object PsObject
  foreach ($header in $csv_headers) {
    Add-Member -InputObject $csv_row -MemberType noteproperty -Name $header -Value ""
  }

  return $csv_row

}

<#
    Format a JSON string in the format expected by DynamoDB
    Strips any escape sequences and adds in multiple sets of brackets
#>
function Format-JSON {

    param (
        [String]$formatted_json,
        [String]$tableName
    )

    <#
    Remove escapes added by ConvertTo-Json
    Replace open brace with { "PutRequest": { "Item" : {
    and replace close brace with } } },
    only match when the open and close braces are on the same line;
    this is done to match DDB formatting requirements.
    #>
    $formatted_json = $formatted_json -replace '\\', ''
    $formatted_json = $formatted_json -replace '[^"\[,]{', "{`n`"PutRequest`": {`n `"Item`": {"
    $formatted_json = $formatted_json -replace '((}[^{\]",])|(},[^{\]"]))', "}`n}`n},`n"
    $formatted_json = $formatted_json -replace '"{', '{'
    $formatted_json = $formatted_json -replace '}"', '}'

    #Remove the trailing comma from the last line
    $len = $formatted_json.length - 4
    $formatted_json = $formatted_json.remove($len, 1)

    #Add the opening and closing braces and the tablename to the String
    $formatted_json = "{`n`"$tableName`": " + $formatted_json + "`n}"

    return $formatted_json

}

#Test if the output path exists and if it doesn't, create it
if (-not (Test-Path -Path (split-path -Path $output_file_basename))) {

    $folder = Split-Path -Path $output_file_basename

    mkdir $folder

}

#Get the CSV file and store it into an Object and get a list of headers from the Object
$formatted_csv = Import-CSV -path $input_file 
$csv_headers = Get-CSVObjectHeaders -inputCsv $formatted_csv

#Loop through the CSV object to reformat the rows into the format expected by DynamoDB
for ($i = 0; $i -lt $formatted_csv.length; $i++) {

  #Iterate over the header names to access the row item for each index
  foreach ($header in $csv_headers) {
    
    $item_length = $formatted_csv[$i].$header.length

    #If the CSV wrapped the cell in quotes we need to get rid of that as JSON won't like it.
    if ($formatted_csv[$i].$header -match '\".*\"' -and -not ($formatted_csv[$i].$header -match '\[(\{"(S|N|BOOL|NULL)":(| )"[a-zA-Z\-_0-9]*"\}(,|, ){0,1})+\]')) {
        $formatted_csv[$i].$header = $formatted_csv[$i].$header.remove(0,1)
        $formatted_csv[$i].$header = $formatted_csv[$i].$header.remove($item_length - 2, 1)
    }

    #Test if the item is numeric or not and format the data accordingly
    #DDB expects a type specifier for each entry, e.g. S, N, B, etc.
    #A list of specifiers can be found here: https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_AttributeValue.html
    if ($formatted_csv[$i].$header -match '^-{0,1}[0-9]+\.{0,1}[0-9]*$') {

        $formatted_csv[$i].$header = "{`"N`": `"$($formatted_csv[$i].$header)`"}" #Number

    } elseif ([String]::IsNullOrWhiteSpace($formatted_csv[$i].$header)) {

        $formatted_csv[$i].$header = "{`"S`": `" `" }" #Null, not using actual null operator b/c HASH/RANGE keys can't be null or blank

    } elseif ($formatted_csv[$i].$header -is [Boolean]) {

        $formatted_csv[$i].$header = "{`"BOOL`": `"$($formatted_csv[$i].$header)`"}" #Boolean

    } elseif ($formatted_csv[$i].$header -match '\[(\{"(S|N|BOOL|NULL)":(| )"[a-zA-Z\-_0-9]*"\}(,|, ){0,1})+\]') {

        $formatted_csv[$i].$header = "{`"L`": $($formatted_csv[$i].$header)}" #List

    } else {

        $formatted_csv[$i].$header = "{`"S`": `"$($formatted_csv[$i].$header)`"}" #String

    }

  }

}

$num_items = $formatted_csv.count

#DDB only supports bulk uploading 25 entries at a time
#If there are more than 25 entries we need to split them into separte files
#And upload those files 1-by-1.

#Create two ArrayLists, one to hold the all the CSV files
#And one to hold the current CSV file
[System.Collections.ArrayList]$Script:csv_files = @()
[System.Collections.ArrayList]$Script:csv_object = @()

#Iterate over $formatted_csv
for ($i = 0; $i -lt $num_items; $i++) {

    $row = $null #Null out row so we know it's cleared before recreating it. Should in theory also free up the memory when GC runs.
    $row = Create-CSVRow -inputCsv $formatted_csv #Call the Create-CSVRow function to get a custom object representing a row in the CSV

    #Add the contents of the CSV object at index $i to our current row object
    foreach ($header in $csv_headers) {
        $row.$header = $formatted_csv[$i].$header 
    }

    $csv_object.Add($row) > $null #Add our row to the current file ArrayList

    #If we have 25 objects in the current file ArrayList
    #Or if we are on the last item, add the current file ArrayList
    #To the all file ArrayList and then re-create the current file ArrayList
    if (($csv_object.Count -eq 25) -or ($i -eq $num_items - 1)) {
        $csv_files.Add($csv_object) > $null #write to null as ArrayList.Add echos the indice of the added item to screen otherwise
        [System.Collections.ArrayList]$Script:csv_object = @()
    }

}

echo "Number of files generated: $($csv_files.Count)"

$counter = 1 #Counter used to append a number to the output files
$filenames = @()

foreach ($file in $csv_files) {

    echo "items in file ${counter}: $($file.Count)"

    $formatted_json = ConvertTo-Json -InputObject $file #convert the current file to a JSON String

    #Call the Format-JSON function from above
    $formatted_json = Format-JSON -formatted_json $formatted_json -tableName $tableName

    #Output the file
    $filenames += "${output_file_basename}${counter}.json"
    echo $formatted_json | set-content "${output_file_basename}${counter}.json" -Encoding Ascii

    $counter++

}

#Verify profile is correct _before_ writing to DB
#read key twice to clear the extraneous enter that is usually in the stdin buffer
Write-Host "`nAbout to write to file using the profile: $aws_profile" -ForegroundColor red
Write-Host "if this is incorrect, please press [ctrl]+c"
Write-Host "otherwise, press any key to continue...`n"
$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyUp") > $null
$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyUp") > $null

#Write the data to DynamoDB
foreach ($file in $filenames) {

    if ($aws_profile -eq 'local') {

        echo "Batch writing items to local DB with following information:`nFilename:`t$file`nProfile:`t$aws_profile"
        aws dynamodb batch-write-item --request-items file://$file --endpoint-url http://localhost:8000 --profile $aws_profile

    } elseif ($aws_profile -eq 'none') {

        echo "Writing items to remote DB with the following information: `nFilename: `t$file`nProfile:`tNone, will use environment variables or default profile"
        aws dynamodb batch-write-item --request-items file://$file

    } else {

        echo "Writing items to remote DB with following information:`nFileName:`t$file`nProfile:`t$aws_profile"
        aws dynamodb batch-write-item --request-items file://$file --profile $aws_profile

    }

}
