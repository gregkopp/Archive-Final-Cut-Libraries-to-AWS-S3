# Archive to S3

This repository contains a script to archive files and upload them to an Amazon S3 bucket using multipart upload. The script splits large files into smaller parts and uploads them in parallel to optimize the upload process.

## Usage

To use the script, run the following command:

```sh
./archive-to-s3.sh <bucket-name> [source-path]
```

## Parameters

- bucket-name: (Required) The name of your S3 bucket
- source-path: (Optional) Path to the directory to archive. Defaults to current working directory if omitted

## Examples

```
# Archive from specific path
./archive-to-s3.sh my-bucket /path/to/archive

# Archive from current directory
./archive-to-s3.sh my-bucket
```

## Disclaimer

This code is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. In no event shall the authors be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.

## License

This script is licensed under the **Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)** license.

### Permissions:

- **Copying and Redistribution**: You are free to copy, redistribute, and modify this script in any medium or format.

### Restrictions:

- **NonCommercial Use Only**: Use of this script is permitted for non-commercial purposes only. Commercial use of any kind is not allowed without prior written permission from the author.

### Requirements:

- **Attribution**: You must give appropriate credit, provide a link to the license, and indicate if changes were made. You may do so in any reasonable manner, but not in any way that suggests the licensor endorses you or your use.

For more information about this license, see the full legal text here: [Creative Commons BY-NC 4.0 License](https://creativecommons.org/licenses/by-nc/4.0/).

## Copyright

© 2025 Greg Kopp. All rights reserved.
