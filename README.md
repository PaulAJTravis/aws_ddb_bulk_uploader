# aws\_ddb\_bulk\_uploader

Program for bulk uploading data to DynamoDB using a CSV file.
Expects a CSV file with headers, where the headers will be used for the column names.

Converts the provided CSV file into JSON and uses AWS CLI to write the file to DDB.
In the event there are more than 25 entries, splits the CSV file into multiple JSON files.
This is done because DynamoDB bulk upload only allows 25 bulk writes at a time.

Use the following syntax to call the program
```PowerShell
.\convert.ps1 -input_file <path to CSV File to Convert> -output_file_basename <path for output file(s)> -tableName <name of DDB table to write to> [-aws_profile] <profile_name>
```

This tool will fail if there is duplicate data to be written in any file.
That file will not be written, but the tool will continue to write other files.
It should still be possible to manually write that file using the AWS CLI V2 as long as you remove the duplicate entries.

Note: Don't include a file extension with the -output\_file\_basename, the JSON extension will be added for you. Additionally this program will create 1 file for every 25 entries to be written, it is recommended to have the output location be a sub-directory.

Doesn't currently support complex data types, currently only supports Numbers, Strings, Booleans, and Nulls.
If you're working with data that requires uploading binary (blobs), sets, maps, or Dates this will likely convert that data to either Strings or Numbers, which might result in problems down the road.
