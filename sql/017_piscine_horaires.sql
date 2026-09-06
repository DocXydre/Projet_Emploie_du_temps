-- =============================================================================
-- 017 : les vrais créneaux de la piscine                              (SPT-2)
--
-- Les horaires posés en 013 étaient une approximation faite avant la rentrée,
-- le SUAPS n'ayant pas encore publié son programme. Ceux-ci viennent de la
-- fiche « Natation — pratique libre ouverte à tous », piscine universitaire des
-- Océanautes à Nancy, relevée le 4 septembre 2026.
--
-- **Volontairement non rejouable.** C'est un état de départ, pas une vérité :
-- la migration 018 met en place un relevé automatique qui écrase ces lignes
-- chaque jour. Rejouer ce fichier ramènerait la photo du 4 septembre par-dessus
-- des horaires plus frais.
-- =============================================================================

DELETE FROM ouverture
 WHERE id_lieu = (SELECT id_lieu FROM lieu_sport WHERE code = 'PISCINE_SUAPS');

INSERT INTO ouverture (id_lieu, jour_semaine, heure_debut, heure_fin)
SELECT l.id_lieu, c.jour, c.debut, c.fin
  FROM lieu_sport l
  CROSS JOIN (VALUES
      (1, TIME '12:30', TIME '13:30'),   -- lundi midi
      (1, TIME '20:30', TIME '22:00'),   -- lundi soir
      (2, TIME '12:30', TIME '13:30'),
      (2, TIME '17:00', TIME '18:30'),
      (3, TIME '12:30', TIME '13:30'),   -- mercredi, midi seulement
      (4, TIME '12:15', TIME '13:15'),
      (4, TIME '20:30', TIME '22:00'),
      (5, TIME '12:15', TIME '13:15'),
      (5, TIME '16:30', TIME '18:00'),
      (6, TIME '09:30', TIME '12:00')    -- samedi matin
  ) AS c(jour, debut, fin)
 WHERE l.code = 'PISCINE_SUAPS'
ON CONFLICT (id_lieu, jour_semaine, heure_debut) DO NOTHING;


-- Deux bornes à corriger.
--
-- heure_max passait à 20:00, ce qui coupait les créneaux du soir : ils
-- existent, autant les connaître. La préférence « au plus tôt » fait de toute
-- façon gagner celui de midi quand les deux sont libres.
--
-- La durée descend à 45 minutes. Les créneaux de midi durent une heure pile, et
-- « ouverture des portes 5 minutes avant, sortie à l'heure de fin » : nager
-- soixante minutes dans un créneau de soixante n'aurait laissé ni vestiaire ni
-- douche.
UPDATE lieu_sport
   SET heure_max     = '22:00',
       duree_minutes = 45
 WHERE code = 'PISCINE_SUAPS';


-- La fiche précise : « Piscine fermée pendant les vacances universitaires, les
-- jours fériés et en période estivale (mi-juin à septembre). » La fermeture
-- estivale est déjà déclarée en 013. Les vacances et les jours fériés se
-- déclarent au fil de l'eau dans `fermeture`, une ligne par période :
--
--   INSERT INTO fermeture (id_lieu, periode, motif)
--   SELECT id_lieu, DATERANGE('2026-12-19', '2027-01-05', '[)'), 'Vacances de Noël'
--     FROM lieu_sport WHERE code = 'PISCINE_SUAPS';
