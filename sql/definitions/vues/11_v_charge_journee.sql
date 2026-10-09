-- PLN-16 : la charge de chaque journée, d'après l'emploi du temps. Les seuils
-- sont ceux de l'annexe B du cahier des charges du coach, à calibrer.
CREATE VIEW v_charge_journee AS
SELECT u.id_utilisateur,
       j.jour::DATE                                               AS jour,
       COALESCE(round(x.minutes / 60.0, 1), 0)                    AS heures,
       (x.debut AT TIME ZONE 'Europe/Paris')::TIME                AS premier_debut,
       (x.fin   AT TIME ZONE 'Europe/Paris')::TIME                AS derniere_fin,
       CASE
           WHEN COALESCE(x.minutes, 0) >= 420
                OR ((x.debut AT TIME ZONE 'Europe/Paris')::TIME < TIME '09:00'
                    AND (x.fin AT TIME ZONE 'Europe/Paris')::TIME > TIME '18:30') THEN 'lourde'
           WHEN COALESCE(x.minutes, 0) >= 240 THEN 'moyenne'
           ELSE 'legere'
       END                                                        AS niveau
  FROM utilisateur u
 CROSS JOIN generate_series(jour_de(now()) - 7, jour_de(now()) + 35, INTERVAL '1 day') AS j(jour)
  LEFT JOIN LATERAL (
      SELECT sum(EXTRACT(EPOCH FROM (upper(o.periode) - lower(o.periode))) / 60) AS minutes,
             min(lower(o.periode)) AS debut,
             max(upper(o.periode)) AS fin
        FROM occupation o
       WHERE o.id_utilisateur = u.id_utilisateur
         AND o.type IN ('cours', 'travail')
         AND o.periode && tstzrange(debut_jour(j.jour::DATE), debut_jour(j.jour::DATE + 1), '[)')
  ) x ON TRUE
 WHERE u.actif;

COMMENT ON VIEW v_charge_journee IS
    'PLN-16 : heures de cours et de travail de chaque jour, début, fin, et
     niveau de charge (légère, moyenne, lourde). Ce que le coach en fait relève
     du dossier : la base ne refuse rien au motif d''une journée lourde.';
