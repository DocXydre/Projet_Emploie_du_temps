package fr.thomasmathis.planif.contraintes;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.List;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.journal.ServiceJournal;
import fr.thomasmathis.planif.sante.EtatSante;

/**
 * Gestion des occupations et des sources.
 *
 * <p>La saisie manuelle est le mode degrade du systeme : elle doit exister des
 * le premier jour, pas etre ajoutee apres la premiere panne de scraper
 * (cf. 7.1 A.4). C'est ce que fournissent {@link #saisirManuellement} et
 * {@link #reconcilier}.</p>
 */
@Service
public class ServiceOccupation {

    public static final String SOURCE_MANUELLE = "SAISIE_MANUELLE";

    private final DepotOccupation depot;
    private final DepotSourceContrainte depotSources;
    private final ServiceJournal journal;
    private final Clock horloge;

    public ServiceOccupation(DepotOccupation depot, DepotSourceContrainte depotSources,
                             ServiceJournal journal, Clock horloge) {
        this.depot = depot;
        this.depotSources = depotSources;
        this.journal = journal;
        this.horloge = horloge;
    }

    @Transactional(readOnly = true)
    public List<Occupation> surPeriode(Long utilisateurId, OffsetDateTime debut, OffsetDateTime fin) {
        if (!fin.isAfter(debut)) {
            throw ExceptionMetier.regleViolee("La fin de periode doit suivre le debut");
        }
        return utilisateurId == null
                ? depot.surPeriode(debut, fin)
                : depot.surPeriodePourUtilisateur(utilisateurId, debut, fin);
    }

    @Transactional
    public Occupation saisirManuellement(String acteur, Long utilisateurId, TypeOccupation type,
                                         OffsetDateTime debut, OffsetDateTime fin,
                                         String libelle, String lieu) {
        if (!fin.isAfter(debut)) {
            throw ExceptionMetier.regleViolee("La fin doit suivre le debut");
        }
        SourceContrainte source = sourceParCode(SOURCE_MANUELLE);

        Occupation occupation = new Occupation(
                utilisateurId, source.getId(), type, debut, fin, libelle, OffsetDateTime.now(horloge));
        occupation.setLieu(lieu);

        Occupation enregistree = depot.save(occupation);
        journal.tracer(acteur, "OCCUPATION_SAISIE", "occupation", enregistree.getId(),
                null, "%s %s au %s".formatted(type, debut, fin));
        return enregistree;
    }

    /**
     * Reconciliation d'une collecte : la cle externe decide s'il faut creer ou
     * mettre a jour. Aucune duplication, aucune suppression physique.
     */
    @Transactional
    public Occupation reconcilier(Long sourceId, Long utilisateurId, String cleExterne, TypeOccupation type,
                                  OffsetDateTime debut, OffsetDateTime fin, String libelle, String lieu,
                                  boolean annulee) {
        OffsetDateTime maintenant = OffsetDateTime.now(horloge);

        Occupation occupation = depot.findBySourceIdAndCleExterne(sourceId, cleExterne)
                .orElseGet(() -> {
                    Occupation nouvelle = new Occupation(
                            utilisateurId, sourceId, type, debut, fin, libelle, maintenant);
                    nouvelle.setCleExterne(cleExterne);
                    return nouvelle;
                });

        occupation.setType(type);
        occupation.setDebut(debut);
        occupation.setFin(fin);
        occupation.setLibelle(libelle);
        occupation.setLieu(lieu);
        occupation.setAnnulee(annulee);
        occupation.setCollecteeLe(maintenant);

        return depot.save(occupation);
    }

    @Transactional
    public void supprimer(String acteur, Long occupationId) {
        Occupation occupation = depot.findById(occupationId)
                .orElseThrow(() -> ExceptionMetier.introuvable("Occupation", occupationId));
        occupation.setAnnulee(true);
        depot.save(occupation);
        journal.tracer(acteur, "OCCUPATION_ANNULEE", "occupation", occupationId,
                occupation.getLibelle(), "annulee");
    }

    @Transactional(readOnly = true)
    public List<SourceContrainte> sources() {
        return depotSources.findAllByOrderByCodeAsc();
    }

    @Transactional(readOnly = true)
    public SourceContrainte sourceParCode(String code) {
        return depotSources.findByCode(code)
                .orElseThrow(() -> ExceptionMetier.introuvable("Source", code));
    }

    /**
     * Recalcule et persiste l'etat de sante de chaque source a partir de sa
     * fraicheur. Une source perimee doit etre visible, pas silencieuse.
     */
    @Transactional
    public List<SourceContrainte> rafraichirEtatsSante() {
        OffsetDateTime maintenant = OffsetDateTime.now(horloge);
        List<SourceContrainte> sources = depotSources.findAllByOrderByCodeAsc();

        for (SourceContrainte source : sources) {
            EtatSante evalue = source.evaluerFraicheur(maintenant);
            if (evalue != source.getEtatSante()) {
                journal.tracer("systeme", "SOURCE_ETAT_CHANGE", "source_contrainte", source.getId(),
                        source.getEtatSante().name(), evalue.name());
                source.setEtatSante(evalue);
                depotSources.save(source);
            }
        }
        return sources;
    }
}
