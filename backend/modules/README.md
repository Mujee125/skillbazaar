# Module rules
1. A module owns its tables. No other module reads or writes them.
2. Other modules call only services.py and ports.py, never models.py.
3. Links across modules store an id only, no ForeignKey (user model: to be decided).
4. Outside systems (SMS, payment) sit behind a port with adapters.
5. Each module has its own tests and runs alone.
