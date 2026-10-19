-- SAN-15 : les séances reçues deux fois avant la migration 069 ne comptent
-- plus qu'une fois, et la séance libre née du doublon se retire.
SELECT departager_activites_existantes();
