package fr.thomasmathis.planif.taches;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.journal.ServiceJournal;
import fr.thomasmathis.planif.securite.UtilisateurCourant;

/**
 * Cycle de vie des occurrences.
 *
 * <p>Trois regles du cahier des charges vivent ici, et nulle part ailleurs :</p>
 * <ul>
 *   <li>la recurrence repart de la <b>date de validation reelle</b>, jamais de
 *       la date theorique (6.4 passe 3, 7.6 F.4) ;</li>
 *   <li>une dependance ne cree pas de doublon : si une occurrence de la tache
 *       cible existe deja dans la fenetre, elle est repositionnee (7.4 D.4) ;</li>
 *   <li>une tache declenchee par dependance ne peut jamais etre placee avant
 *       sa source.</li>
 * </ul>
 */
@Service
public class ServiceOccurrenceTache {

    private static final Logger LOG = LoggerFactory.getLogger(ServiceOccurrenceTache.class);

    /** Etats consideres comme « encore a faire » pour les recherches. */
    private static final List<EtatOccurrence> ETATS_OUVERTS = List.of(
            EtatOccurrence.PLANIFIEE,
            EtatOccurrence.NOTIFIEE,
            EtatOccurrence.GELEE,
            EtatOccurrence.NON_PLANIFIABLE);

    private final DepotOccurrenceTache depot;
    private final DepotDefinitionTache depotDefinitions;
    private final DepotDependanceTache depotDependances;
    private final ServiceJournal journal;
    private final Clock horloge;

    public ServiceOccurrenceTache(DepotOccurrenceTache depot,
                                  DepotDefinitionTache depotDefinitions,
                                  DepotDependanceTache depotDependances,
                                  ServiceJournal journal,
                                  Clock horloge) {
        this.depot = depot;
        this.depotDefinitions = depotDefinitions;
        this.depotDependances = depotDependances;
        this.journal = journal;
        this.horloge = horloge;
    }

    // ------------------------------------------------------------------
    // Lecture
    // ------------------------------------------------------------------

    @Transactional(readOnly = true)
    public OccurrenceTache parId(Long id) {
        return depot.findById(id).orElseThrow(() -> ExceptionMetier.introuvable("Occurrence", id));
    }

    @Transactional(readOnly = true)
    public List<OccurrenceTache> rechercher(List<EtatOccurrence> etats, Long assigneA) {
        List<EtatOccurrence> filtre = (etats == null || etats.isEmpty()) ? ETATS_OUVERTS : etats;
        return assigneA == null
                ? depot.findByEtatInOrderByEcheanceMaxAsc(filtre)
                : depot.findByAssigneAAndEtatInOrderByEcheanceMaxAsc(assigneA, filtre);
    }

    @Transactional(readOnly = true)
    public List<OccurrenceTache> enRetard() {
        return depot.enRetard(ETATS_OUVERTS, OffsetDateTime.now(horloge));
    }

    // ------------------------------------------------------------------
    // Creation
    // ------------------------------------------------------------------

    /**
     * Cree l'occurrence suivante d'une definition a partir d'une date de
     * reference. La fenetre d'echeance derive des intervalles de la definition.
     */
    @Transactional
    public OccurrenceTache creerSuivante(DefinitionTache definition, OffsetDateTime reference,
                                         OrigineOccurrence origine, Long occurrenceParenteId) {
        OccurrenceTache occurrence = new OccurrenceTache(
                definition.getId(),
                reference.plusDays(definition.getIntervalleMinJours()),
                reference.plusDays(definition.getIntervalleMaxJours()),
                origine);
        occurrence.setAssigneA(definition.getAssignationParDefaut());
        occurrence.setOccurrenceParenteId(occurrenceParenteId);
        return depot.save(occurrence);
    }

    /**
     * Creation manuelle ou forcage. Une occurrence forcee est epinglee d'office :
     * elle ne doit pas etre deplacee par la replanification suivante (7.3 C.3).
     */
    @Transactional
    public OccurrenceTache creerManuelle(UtilisateurCourant acteur, Long definitionId, Long assigneA,
                                         OffsetDateTime echeanceMin, OffsetDateTime echeanceMax,
                                         OffsetDateTime creneauDebut, OffsetDateTime creneauFin,
                                         String motif) {
        DefinitionTache definition = depotDefinitions.findById(definitionId)
                .orElseThrow(() -> ExceptionMetier.introuvable("Definition", definitionId));

        if (echeanceMax.isBefore(echeanceMin)) {
            throw ExceptionMetier.regleViolee("L'echeance maximale precede l'echeance minimale");
        }

        OccurrenceTache occurrence = new OccurrenceTache(
                definition.getId(), echeanceMin, echeanceMax, OrigineOccurrence.MANUELLE);
        occurrence.setAssigneA(assigneA != null ? assigneA : definition.getAssignationParDefaut());
        occurrence.setCreneauDebut(creneauDebut);
        occurrence.setCreneauFin(creneauFin);
        occurrence.setEpinglee(creneauDebut != null);
        occurrence.setMotif(motif != null ? motif : "Creation manuelle");

        OccurrenceTache enregistree = depot.save(occurrence);
        journal.tracer(acteur.identifiant(), "OCCURRENCE_CREEE_MANUELLEMENT", "occurrence_tache",
                enregistree.getId(), null, definition.getCode());
        return enregistree;
    }

    // ------------------------------------------------------------------
    // Transitions
    // ------------------------------------------------------------------

    /**
     * Validation, eventuellement retroactive.
     *
     * @param dateReelle date a laquelle la tache a reellement ete faite. C'est
     *                   elle qui alimente le recalcul de la prochaine occurrence.
     */
    @Transactional
    public ResultatValidation valider(UtilisateurCourant acteur, Long occurrenceId, OffsetDateTime dateReelle) {
        OccurrenceTache occurrence = parId(occurrenceId);
        acteur.verifierDroitSur(occurrence.getAssigneA());

        OffsetDateTime maintenant = OffsetDateTime.now(horloge);
        OffsetDateTime date = dateReelle != null ? dateReelle : maintenant;
        if (date.isAfter(maintenant)) {
            throw ExceptionMetier.regleViolee("Une tache ne peut pas etre validee dans le futur");
        }

        EtatOccurrence avant = occurrence.getEtat();
        MachineEtatsOccurrence.appliquer(occurrence, EtatOccurrence.VALIDEE);
        occurrence.setValideeLe(date);
        occurrence.setValideePar(acteur.id());
        depot.save(occurrence);

        String typeEvenement = acteur.agitPourAutrui(occurrence.getAssigneA())
                ? "OCCURRENCE_VALIDEE_EN_DEPANNAGE"   // trace explicitement (cf. 3.3)
                : "OCCURRENCE_VALIDEE";
        journal.tracer(acteur.identifiant(), typeEvenement, "occurrence_tache", occurrenceId,
                avant.name(), "VALIDEE le " + date);

        DefinitionTache definition = depotDefinitions.findById(occurrence.getDefinitionId())
                .orElseThrow(() -> ExceptionMetier.introuvable("Definition", occurrence.getDefinitionId()));

        List<OccurrenceTache> declenchees = declencherDependances(definition, date);

        // La recurrence repart de la date reelle : une tache faite en retard ne
        // doit pas fausser tout le reste du planning.
        OccurrenceTache suivante = definition.isActive()
                ? creerSuivante(definition, date, OrigineOccurrence.AUTOMATIQUE, occurrenceId)
                : null;

        return new ResultatValidation(occurrence, Optional.ofNullable(suivante), declenchees);
    }

    /** Report : l'occurrence courante est soldee et une nouvelle prend le relais. */
    @Transactional
    public OccurrenceTache reporter(UtilisateurCourant acteur, Long occurrenceId,
                                    OffsetDateTime nouvelleEcheanceMax, String motif) {
        OccurrenceTache occurrence = parId(occurrenceId);
        acteur.verifierDroitSur(occurrence.getAssigneA());

        OffsetDateTime maintenant = OffsetDateTime.now(horloge);
        OffsetDateTime nouvelleMax = nouvelleEcheanceMax != null
                ? nouvelleEcheanceMax
                : occurrence.getEcheanceMax().plusDays(1);

        if (!nouvelleMax.isAfter(maintenant)) {
            throw ExceptionMetier.regleViolee("La nouvelle echeance doit etre dans le futur");
        }

        MachineEtatsOccurrence.appliquer(occurrence, EtatOccurrence.REPORTEE);
        occurrence.setMotif(motif != null ? motif : "Reportee par " + acteur.identifiant());
        depot.save(occurrence);

        OccurrenceTache remplacante = new OccurrenceTache(
                occurrence.getDefinitionId(), maintenant, nouvelleMax, OrigineOccurrence.MANUELLE);
        remplacante.setAssigneA(occurrence.getAssigneA());
        remplacante.setOccurrenceParenteId(occurrenceId);
        remplacante.setMotif("Report de l'occurrence " + occurrenceId);
        remplacante = depot.save(remplacante);

        journal.tracer(acteur.identifiant(), "OCCURRENCE_REPORTEE", "occurrence_tache", occurrenceId,
                occurrence.getEcheanceMax().toString(), nouvelleMax.toString());
        return remplacante;
    }

    /**
     * Refus. Une tache refusee ne disparait pas : elle est recreee, desassignee,
     * pour etre reprise par la replanification ou reassignee a la main. Une tache
     * qui resterait due indefiniment sur une seule personne finit par pourrir
     * l'usage de l'outil (cf. 7.4 D.5).
     */
    @Transactional
    public OccurrenceTache refuser(UtilisateurCourant acteur, Long occurrenceId, String motif) {
        OccurrenceTache occurrence = parId(occurrenceId);
        acteur.verifierDroitSur(occurrence.getAssigneA());

        MachineEtatsOccurrence.appliquer(occurrence, EtatOccurrence.REFUSEE);
        occurrence.setMotif(motif != null ? motif : "Refusee par " + acteur.identifiant());
        depot.save(occurrence);

        OccurrenceTache reprise = new OccurrenceTache(
                occurrence.getDefinitionId(),
                occurrence.getEcheanceMin(),
                occurrence.getEcheanceMax(),
                OrigineOccurrence.MANUELLE);
        reprise.setOccurrenceParenteId(occurrenceId);
        reprise.setMotif("Refus de %s : a reassigner".formatted(acteur.identifiant()));
        reprise = depot.save(reprise);

        journal.tracer(acteur.identifiant(), "OCCURRENCE_REFUSEE", "occurrence_tache", occurrenceId,
                String.valueOf(occurrence.getAssigneA()), "desassignee");
        return reprise;
    }

    /** Gel par un statut global. Une definition non gelable refuse le gel. */
    @Transactional
    public OccurrenceTache geler(String acteur, Long occurrenceId, String motif) {
        OccurrenceTache occurrence = parId(occurrenceId);
        DefinitionTache definition = depotDefinitions.findById(occurrence.getDefinitionId())
                .orElseThrow(() -> ExceptionMetier.introuvable("Definition", occurrence.getDefinitionId()));

        if (!definition.isGelable()) {
            throw ExceptionMetier.regleViolee(
                    "La tache %s n'est pas gelable : elle reste due".formatted(definition.getCode()));
        }

        MachineEtatsOccurrence.appliquer(occurrence, EtatOccurrence.GELEE);
        occurrence.setMotif(motif);
        journal.tracer(acteur, "OCCURRENCE_GELEE", "occurrence_tache", occurrenceId, null, motif);
        return depot.save(occurrence);
    }

    @Transactional
    public OccurrenceTache degeler(String acteur, Long occurrenceId) {
        OccurrenceTache occurrence = parId(occurrenceId);
        MachineEtatsOccurrence.appliquer(occurrence, EtatOccurrence.PLANIFIEE);
        occurrence.setMotif(null);
        journal.tracer(acteur, "OCCURRENCE_DEGELEE", "occurrence_tache", occurrenceId, "GELEE", "PLANIFIEE");
        return depot.save(occurrence);
    }

    @Transactional
    public OccurrenceTache marquerNotifiee(Long occurrenceId) {
        OccurrenceTache occurrence = parId(occurrenceId);
        MachineEtatsOccurrence.appliquer(occurrence, EtatOccurrence.NOTIFIEE);
        // Un creneau communique est epingle : il ne bouge plus sans raison (6.5).
        occurrence.setEpinglee(true);
        return depot.save(occurrence);
    }

    @Transactional
    public OccurrenceTache reassigner(UtilisateurCourant acteur, Long occurrenceId, Long nouvelAssigne) {
        OccurrenceTache occurrence = parId(occurrenceId);
        Long avant = occurrence.getAssigneA();
        occurrence.setAssigneA(nouvelAssigne);
        journal.tracer(acteur.identifiant(), "OCCURRENCE_REASSIGNEE", "occurrence_tache", occurrenceId,
                String.valueOf(avant), String.valueOf(nouvelAssigne));
        return depot.save(occurrence);
    }

    // ------------------------------------------------------------------
    // Dependances
    // ------------------------------------------------------------------

    /**
     * Cree ou repositionne les occurrences declenchees par la validation d'une
     * tache source. Exemple : la poussiere validee a 18h impose l'aspirateur
     * avant 18h le lendemain, et jamais avant 18h aujourd'hui.
     */
    private List<OccurrenceTache> declencherDependances(DefinitionTache source, OffsetDateTime dateSource) {
        List<OccurrenceTache> resultat = new ArrayList<>();

        for (DependanceTache dependance : depotDependances.findByDefinitionSourceId(source.getId())) {
            OffsetDateTime limite = dateSource.plusHours(dependance.getDelaiMaxHeures());

            List<OccurrenceTache> existantes = depot.ouvertesDansFenetre(
                    dependance.getDefinitionCibleId(), ETATS_OUVERTS, dateSource, limite);

            if (!existantes.isEmpty()) {
                // Anti-doublon : on repositionne la premiere au lieu d'en creer une seconde.
                OccurrenceTache aRepositionner = existantes.get(0);
                aRepositionner.setEcheanceMin(dateSource);
                aRepositionner.setEcheanceMax(plusTot(aRepositionner.getEcheanceMax(), limite, dateSource));
                aRepositionner.setMotif("Repositionnee apres %s".formatted(source.getCode()));
                resultat.add(depot.save(aRepositionner));

                if (existantes.size() > 1) {
                    LOG.warn("{} occurrences ouvertes de la definition {} dans la fenetre de dependance",
                            existantes.size(), dependance.getDefinitionCibleId());
                }
                continue;
            }

            DefinitionTache cible = depotDefinitions.findById(dependance.getDefinitionCibleId())
                    .orElseThrow(() -> ExceptionMetier.introuvable("Definition",
                            dependance.getDefinitionCibleId()));
            if (!cible.isActive()) {
                continue;
            }

            OccurrenceTache declenchee = new OccurrenceTache(
                    cible.getId(), dateSource, limite, OrigineOccurrence.DEPENDANCE);
            declenchee.setAssigneA(cible.getAssignationParDefaut());
            declenchee.setMotif("Declenchee par %s".formatted(source.getCode()));
            resultat.add(depot.save(declenchee));
        }

        return resultat;
    }

    /**
     * Conserve la contrainte la plus serree entre l'echeance existante et la
     * limite de dependance, sans jamais passer avant la tache source.
     */
    private OffsetDateTime plusTot(OffsetDateTime existante, OffsetDateTime limite, OffsetDateTime plancher) {
        OffsetDateTime retenue = existante.isBefore(limite) ? existante : limite;
        return retenue.isBefore(plancher) ? limite : retenue;
    }

    /** Resultat d'une validation : ce qui a ete solde, recree et declenche. */
    public record ResultatValidation(OccurrenceTache validee,
                                     Optional<OccurrenceTache> suivante,
                                     List<OccurrenceTache> declenchees) {
    }
}
