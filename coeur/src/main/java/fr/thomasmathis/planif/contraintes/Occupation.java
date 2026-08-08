package fr.thomasmathis.planif.contraintes;

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
 * Occupation subie et non deplaçable. C'est la matiere premiere du calcul de
 * disponibilites : la journee moins les occupations donne les intervalles libres.
 */
@Entity
@Table(name = "occupation")
public class Occupation {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "utilisateur_id", nullable = false)
    private Long utilisateurId;

    @Column(name = "source_id", nullable = false)
    private Long sourceId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private TypeOccupation type;

    @Column(nullable = false)
    private OffsetDateTime debut;

    @Column(nullable = false)
    private OffsetDateTime fin;

    @Column
    private String lieu;

    @Column(nullable = false)
    private String libelle;

    /** UID d'un evenement ICS, identifiant de shift : permet de mettre a jour au lieu de dupliquer. */
    @Column(name = "cle_externe")
    private String cleExterne;

    @Column(nullable = false)
    private boolean annulee = false;

    @Column(name = "collectee_le", nullable = false)
    private OffsetDateTime collecteeLe;

    protected Occupation() {
        // requis par JPA
    }

    public Occupation(Long utilisateurId, Long sourceId, TypeOccupation type,
                      OffsetDateTime debut, OffsetDateTime fin, String libelle, OffsetDateTime collecteeLe) {
        this.utilisateurId = utilisateurId;
        this.sourceId = sourceId;
        this.type = type;
        this.debut = debut;
        this.fin = fin;
        this.libelle = libelle;
        this.collecteeLe = collecteeLe;
    }

    public boolean chevauche(OffsetDateTime debutAutre, OffsetDateTime finAutre) {
        return !annulee && debut.isBefore(finAutre) && fin.isAfter(debutAutre);
    }

    public Long getId() {
        return id;
    }

    public Long getUtilisateurId() {
        return utilisateurId;
    }

    public Long getSourceId() {
        return sourceId;
    }

    public TypeOccupation getType() {
        return type;
    }

    public void setType(TypeOccupation type) {
        this.type = type;
    }

    public OffsetDateTime getDebut() {
        return debut;
    }

    public void setDebut(OffsetDateTime debut) {
        this.debut = debut;
    }

    public OffsetDateTime getFin() {
        return fin;
    }

    public void setFin(OffsetDateTime fin) {
        this.fin = fin;
    }

    public String getLieu() {
        return lieu;
    }

    public void setLieu(String lieu) {
        this.lieu = lieu;
    }

    public String getLibelle() {
        return libelle;
    }

    public void setLibelle(String libelle) {
        this.libelle = libelle;
    }

    public String getCleExterne() {
        return cleExterne;
    }

    public void setCleExterne(String cleExterne) {
        this.cleExterne = cleExterne;
    }

    public boolean isAnnulee() {
        return annulee;
    }

    public void setAnnulee(boolean annulee) {
        this.annulee = annulee;
    }

    public OffsetDateTime getCollecteeLe() {
        return collecteeLe;
    }

    public void setCollecteeLe(OffsetDateTime collecteeLe) {
        this.collecteeLe = collecteeLe;
    }
}
