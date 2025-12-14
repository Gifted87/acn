# Clean Mnesia Schema script
require Logger

Logger.info("Stopping Mnesia...")
:mnesia.stop()

Logger.info("Deleting Schema...")
:mnesia.delete_schema([node()])

Logger.info("Mnesia Cleaned.")
