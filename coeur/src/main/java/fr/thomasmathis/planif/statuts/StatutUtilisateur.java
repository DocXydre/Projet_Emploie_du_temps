package fr.thomasmathis.planif.statuts;

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
 * Un statut declare. Un seul statut ouvert par utilisateur a un instant donne,
 * l'historique est conserve (cf. 5.1).
 */
@Entity
@Table(name = "statut_utilisateur")
public class StatutUtilisateur {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "utilisateur_id", nullable = false)
    private Long utilisateurId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private TypeStatut type;

    /** Renseigne pour un statut ABSENT : « Saint-Die », « vacances ». */
    @Column
    private String lieu;

    @Column(nullable = false)
    private OffsetDateTime debut;

    @Column(name = "fin_prevue")
    private OffsetDateTime finPrevue;

    /** Tant que cette date est nulle, le statut est ouvert. */
    @Column(name = "fin_reelle")
    private OffsetDateTime finReelle;

    @Column
    private String commentaire;

    protected StatutUtilisateur() {
        // requis par JPA
    }

    public StatutUtilisateur(Long utilisateurId, TypeStatut type, OffsetDateTime debut) {
        this.utilisateurId = utilisateurId;
        this.type = type;
        this.debut = debut;
    }

    public boolean estOuvert() {
        return finReelle == null;
    }

    public void terminer(OffsetDateTime fin) {
        this.finReelle = fin;
    }

    public Long getId() {
        return id;
    }

    public Long getUtilisateurId() {
        return utilisateurId;
    }

    public TypeStatut getType() {
        return type;
    }

    public String getLieu() {
        return lieu;
    }

    public void setLieu(String lieu) {
        this.lieu = lieu;
    }

    public OffsetDateTime getDebut() {
        return debut;
    }

    public void setDebut(OffsetDateTime debut) {
        this.debut = debut;
    }

    public OffsetDateTime getFinPrevue() {
        return finPrevue;
    }

    public void setFinPrevue(OffsetDateTime finPrevue) {
        this.finPrevue = finPrevue;
    }

    public OffsetDateTime getFinReelle() {
        return finReelle;
    }

    public String getCommentaire() {
        return commentaire;
    }

    public void setCommentaire(String commentaire) {
        this.commentaire = commentaire;
    }
}
