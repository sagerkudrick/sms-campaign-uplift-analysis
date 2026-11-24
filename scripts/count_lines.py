"""Print the number of lines in a (large) file. Used to check that the SQL load got every row."""
import sys

lines = 0
with open(sys.argv[1], "rb") as f:
    while True:
        chunk = f.read(16 * 1024 * 1024)   # read 16 MB at a time instead of the whole 4.4 GB file
        if not chunk:
            break
        lines += chunk.count(b"\n")
print(lines)
