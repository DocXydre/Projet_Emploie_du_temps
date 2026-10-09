-- Chapitre 8.1 du dossier : la charge d'une séance est sa note d'effort
-- multipliée par sa durée. C'est la seule mesure qui s'additionne d'une
-- discipline à l'autre.
CREATE VIEW v_charge_entrainement AS
SELECT u.id_utilisateur,
       x.charge_7j,
       x.charge_28j,
       x.premier_bilan,
       -- Le rapport ne vaut rien sans quatre semaines d'historique : il reste vide.
       CASE WHEN x.premier_bilan <= jour_de(now()) - 28 AND x.charge_28j > 0
            THEN round(x.charge_7j / (x.charge_28j / 4.0), 2) END AS rapport,
       -- SAI-13 : les séances faites sans bilan n'ont pas de charge. Elles
       -- n'entrent pas dans les sommes, et le coach lit combien il y en a.
       x.seances_7j,
       x.seances_sans_bilan_28j
  FROM utilisateur u
 CROSS JOIN LATERAL (
      SELECT COALESCE(sum(s.charge) FILTER (WHERE s.jour > jour_de(now()) - 7), 0)  AS charge_7j,
             COALESCE(sum(s.charge) FILTER (WHERE s.jour > jour_de(now()) - 28), 0) AS charge_28j,
             (SELECT min(s2.jour) FROM v_seance_coach s2
               WHERE s2.id_utilisateur = u.id_utilisateur AND s2.charge IS NOT NULL) AS premier_bilan,
             count(*) FILTER (WHERE s.jour > jour_de(now()) - 7
                                AND s.situation = 'faite')::INTEGER                 AS seances_7j,
             count(*) FILTER (WHERE s.jour > jour_de(now()) - 28
                                AND s.situation = 'faite'
                                AND s.charge IS NULL)::INTEGER                      AS seances_sans_bilan_28j
        FROM v_seance_coach s
       WHERE s.id_utilisateur = u.id_utilisateur
         AND s.jour > jour_de(now()) - 28
  ) x
 WHERE u.coach_actif;

COMMENT ON VIEW v_charge_entrainement IS
    'Chapitre 8.1, SAI-13 : charge sur 7 et 28 jours et leur rapport, vide tant
     qu''il n''y a pas quatre semaines d''historique. Rend aussi le nombre de
     séances faites sans bilan, donc sans charge.';
