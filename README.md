# SQL Calendar Table

This SQL script generates a calendar table.
First the script scans the database for all date related columns. You have the option to exclude certain columns from this scan.
Then it determines the earliest and latest date referenced across the database.
Once ze have defined the initial date range we expand the range to a clean start and end of a fiscal year.
Based on these final bounds a celander table is generated.
