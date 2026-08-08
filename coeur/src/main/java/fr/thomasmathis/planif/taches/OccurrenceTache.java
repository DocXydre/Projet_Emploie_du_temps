package fr.thomasmathis.planif.taches;

import java.time.OffsetDateTime;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Une execution concrete d'une definition.
 *
 * <p>Une occurrence n'a jamais une date unique : elle a une fenetre d'echeance
 * {@code echeance_min} / {@code echeance_max}, et eventuellement un creneau
 * propose par le moteur, qui peut bouger tant qu'il n'est pas epingle.</p>
 */
@Entity
@Table(name = "occurrence_tache")
public class OccurrenceTache {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "definition_id", nullable = false)
    private Long definitionId;

    @Column(name = "assigne_a")
    private Long assigneA;

    @Column(name = "echeance_min", nullable = false)
    private OffsetDateTime echeanceMin;

    @Column(name = "echeance_max", nullable = false)
    private OffsetDateTime echeanceMax;

    @Column(name = "creneau_debut")
    private OffsetDateTime creneauDebut;

    @Column(name = "creneau_fin")
    private OffsetDateTime creneauFin;

    @Column(nullable = false)
    private boolean epinglee = false;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private EtatOccurrence etat = EtatOccurrence.PLANIFIEE;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private OrigineOccurrence origine = OrigineOccurrence.AUTOMATIQUE;

    /** Motif lisible : « placee a 18h car dernier creneau de 3h avant echeance » (5.5). */
    @Column
    private String motif;

    @Column(name = "validee_le")
    private OffsetDateTime valideeLe;

    @Column(name = "validee_par")
    private Long valideePar;

    @Column(name = "occurrence_parente_id")
    private Long occurrenceParenteId;

    @Column(name = "creee_le", nullable = false, insertable = false, updatable = false)
    private OffsetDateTime creeeLe;

    protected OccurrenceTache() {
        // requis par JPA
    }

    public OccurrenceTache(Long definitionId, OffsetDateTime echeanceMin, OffsetDateTime echeanceMax,
                           OrigineOccurrence origine) {
        this.definitionId = definitionId;
        this.echeanceMin = echeanceMin;
        this.echeanceMax = echeanceMax;
        this.origine = origine;
    }

    /**
     * Une occurrence est en retard des que son echeance maximale est depassee
     * et qu'elle n'est pas soldee. C'est l'API qui le dit, jamais le client
     * (cf. cahier des charges, 8.4).
     */
    public boolean estEnRetard(OffsetDateTime maintenant) {
        return etat.estOuverte() && echeanceMax.isBefore(maintenant);
    }

    public Long getId() {
        return id;
    }

    public Long getDefinitionId() {
        return definitionId;
    }

    public Long getAssigneA() {
        return assigneA;
    }

    public void setAssigneA(Long assigneA) {
        this.assigneA = assigneA;
    }

    public OffsetDateTime getEcheanceMin() {
        return echeanceMin;
    }

    public void setEcheanceMin(OffsetDateTime echeanceMin) {
        this.echeanceMin = echeanceMin;
    }

    public OffsetDateTime getEcheanceMax() {
        return echeanceMax;
    }

    public void setEcheanceMax(OffsetDateTime echeanceMax) {
        this.echeanceMax = echeanceMax;
    }

    public OffsetDateTime getCreneauDebut() {
        return creneauDebut;
    }

    public void setCreneauDebut(OffsetDateTime creneauDebut) {
        this.creneauDebut = creneauDebut;
    }

    public OffsetDateTime getCreneauFin() {
        return creneauFin;
    }

    public void setCreneauFin(OffsetDateTime creneauFin) {
        this.creneauFin = creneauFin;
    }

    public boolean isEpinglee() {
        return epinglee;
    }

    public void setEpinglee(boolean epinglee) {
        this.epinglee = epinglee;
    }

    public EtatOccurrence getEtat() {
        return etat;
    }

    /** Reserve a {@link MachineEtatsOccurrence}, qui verifie la transition. */
    void appliquerEtat(EtatOccurrence etat) {
        this.etat = etat;
    }

    public OrigineOccurrence getOrigine() {
        return origine;
    }

    public void setOrigine(OrigineOccurrence origine) {
        this.origine = origine;
    }

    public String getMotif() {
        return motif;
    }

    public void setMotif(String motif) {
        this.motif = motif;
    }

    public OffsetDateTime getValideeLe() {
        return valideeLe;
    }

    public void setValideeLe(OffsetDateTime valideeLe) {
        this.valideeLe = valideeLe;
    }

    public Long getValideePar() {
        return valideePar;
    }

    public void setValideePar(Long valideePar) {
        this.valideePar = valideePar;
    }

    public Long getOccurrenceParenteId() {
        return occurrenceParenteId;
    }

    public void setOccurrenceParenteId(Long occurrenceParenteId) {
        this.occurrenceParenteId = occurrenceParenteId;
    }

    public OffsetDateTime getCreeeLe() {
        return creeeLe;
    }
}
