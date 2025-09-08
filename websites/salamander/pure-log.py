input_file = "/Users/meti/Projects/wp-ansible/logs/salamander/error.log"
output_file = "/Users/meti/Projects/wp-ansible/logs/salamander/error_cleaned.log"

with open(input_file, "r") as infile, open(output_file, "w") as outfile:
    for line in infile:
        if "WP_MEMORY_LIMIT" not in line:
            outfile.write(line)

print(f"Lines containing 'WP_MEMORY_LIMIT' have been removed. Cleaned file saved as {output_file}.")