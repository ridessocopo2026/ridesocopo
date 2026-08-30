SELECT pg_get_constraintdef(oid) AS constraint_def FROM pg_constraint WHERE conname = 'ride_incidents_incident_type_check';
