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
 * Un trajet propose ou confirme.
 *
 * <p>Un trajet {@code SUGGERE} n'a aucun effet sur le planning. Seule la
 * confirmation cree une occupation et declenche le statut ABSENT (7.2 B.4).</p>
 */
@Entity
@Table(name = "trajet")
public class Trajet {

    public enum Sens {
        ALLER,
        RETOUR
    }

    public enum Etat {
        SUGGERE,
        CONFIRME,
        ANNULE
    }

    public enum SourceConfirmation {
        MAIL,
        MANUEL
    }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "utilisateur_id", nullable = false)
    private Long utilisateurId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private Sens sens;

    @Column(nullable = false)
    private OffsetDateTime depart;

    @Column(nullable = false)
    private OffsetDateTime arrivee;

    @Column(name = "gare_depart", nullable = false)
    private String gareDepart;

    @Column(name = "gare_arrivee", nullable = false)
    private String gareArrivee;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private Etat etat = Etat.SUGGERE;

    @Enumerated(EnumType.STRING)
    @Column(name = "source_confirmation")
    private SourceConfirmation sourceConfirmation;

    @Column(name = "reference_billet")
    private String referenceBillet;

    protected Trajet() {
        // requis par JPA
    }

    public Trajet(Long utilisateurId, Sens sens, OffsetDateTime depart, OffsetDateTime arrivee,
                  String gareDepart, String gareArrivee) {
        this.utilisateurId = utilisateurId;
        this.sens = sens;
        this.depart = depart;
        this.arrivee = arrivee;
        this.gareDepart = gareDepart;
        this.gareArrivee = gareArrivee;
    }

    /** La realite gagne sur la regle : un billet detecte confirme le trajet sans discuter. */
    public void confirmer(SourceConfirmation source, String referenceBillet) {
        this.etat = Etat.CONFIRME;
        this.sourceConfirmation = source;
        this.referenceBillet = referenceBillet;
    }

    public Long getId() {
        return id;
    }

    public Long getUtilisateurId() {
        return utilisateurId;
    }

    public Sens getSens() {
        return sens;
    }

    public OffsetDateTime getDepart() {
        return depart;
    }

    public void setDepart(OffsetDateTime depart) {
        this.depart = depart;
    }

    public OffsetDateTime getArrivee() {
        return arrivee;
    }

    public void setArrivee(OffsetDateTime arrivee) {
        this.arrivee = arrivee;
    }

    public String getGareDepart() {
        return gareDepart;
    }

    public String getGareArrivee() {
        return gareArrivee;
    }

    public Etat getEtat() {
        return etat;
    }

    public void setEtat(Etat etat) {
        this.etat = etat;
    }

    public SourceConfirmation getSourceConfirmation() {
        return sourceConfirmation;
    }

    public String getReferenceBillet() {
        return referenceBillet;
    }
}
