import sqlite3
import os.path
import traceback


if __name__ == '__main__':
    while True:
        database = input("Please input database location: \n")
        if os.path.isfile(database):
            break
        else:
            print("Not a file!")
    try:
        conn = sqlite3.connect(database)   
        cursor = conn.cursor() 
    except:
        print("Database couldn't be loaded")
        traceback.print_exc()
        
    objects = [int(item) for item in input("Please input object identifiers for search, separated by spaces: \n").split()]
    
    
    
    
    cursor.close()
    conn.close()