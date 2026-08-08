package fr.thomasmathis.planif.journal;

import java.time.OffsetDateTime;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Trace d'une action : auteur, horodatage, valeur precedente et nouvelle valeur.
 * Toute action manuelle est journalisee (cf. cahier des charges, 3.3).
 */
@Entity
@Table(name = "journal_evenement")
public class JournalEvenement {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false)
    private OffsetDateTime date;

    @Column(nullable = false)
    private String acteur;

    @Column(nullable = false)
    private String type;

    @Column(nullable = false)
    private String entite;

    @Column(name = "entite_id")
    private Long entiteId;

    @Column(name = "valeur_avant")
    private String valeurAvant;

    @Column(name = "valeur_apres")
    private String valeurApres;

    @Column
    private String correlation;

    protected JournalEvenement() {
        // requis par JPA
    }

    public JournalEvenement(OffsetDateTime date, String acteur, String type, String entite, Long entiteId,
                            String valeurAvant, String valeurApres, String correlation) {
        this.date = date;
        this.acteur = acteur;
        this.type = type;
        this.entite = entite;
        this.entiteId = entiteId;
        this.valeurAvant = valeurAvant;
        this.valeurApres = valeurApres;
        this.correlation = correlation;
    }

    public Long getId() {
        return id;
    }

    public OffsetDateTime getDate() {
        return date;
    }

    public String getActeur() {
        return acteur;
    }

    public String getType() {
        return type;
    }

    public String getEntite() {
        return entite;
    }

    public Long getEntiteId() {
        return entiteId;
    }

    public String getValeurAvant() {
        return valeurAvant;
    }

    public String getValeurApres() {
        return valeurApres;
    }

    public String getCorrelation() {
        return correlation;
    }
}
