package fr.thomasmathis.planif.statuts;

import fr.thomasmathis.planif.taches.CategorieTache;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Effet d'un statut sur une categorie, stocke en base et non code en dur.
 * C'est ce qui permettra d'ajouter un statut VACANCES sans toucher au moteur.
 */
@Entity
@Table(name = "regle_statut")
public class RegleStatut {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Enumerated(EnumType.STRING)
    @Column(name = "type_statut", nullable = false)
    private TypeStatut typeStatut;

    @Enumerated(EnumType.STRING)
    @Column(name = "categorie_tache", nullable = false)
    private CategorieTache categorieTache;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private EffetStatut effet;

    @Column(name = "cible_reassignation")
    private Long cibleReassignation;

    protected RegleStatut() {
        // requis par JPA
    }

    public RegleStatut(TypeStatut typeStatut, CategorieTache categorieTache, EffetStatut effet) {
        this.typeStatut = typeStatut;
        this.categorieTache = categorieTache;
        this.effet = effet;
    }

    public Long getId() {
        return id;
    }

    public TypeStatut getTypeStatut() {
        return typeStatut;
    }

    public CategorieTache getCategorieTache() {
        return categorieTache;
    }

    public EffetStatut getEffet() {
        return effet;
    }

    public void setEffet(EffetStatut effet) {
        this.effet = effet;
    }

    public Long getCibleReassignation() {
        return cibleReassignation;
    }

    public void setCibleReassignation(Long cibleReassignation) {
        this.cibleReassignation = cibleReassignation;
    }
}
