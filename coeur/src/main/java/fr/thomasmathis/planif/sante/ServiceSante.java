package fr.thomasmathis.planif.sante;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

@Service
public class ServiceSante {

    private static final Logger LOG = LoggerFactory.getLogger(ServiceSante.class);

    private final JdbcTemplate jdbc;
    private final Clock horloge;
    private final String version;

    public ServiceSante(JdbcTemplate jdbc, Clock horloge, @Value("${planif.version:dev}") String version) {
        this.jdbc = jdbc;
        this.horloge = horloge;
        this.version = version;
    }

    public ReponseSante etatCourant() {
        Map<String, EtatSante> dependances = new LinkedHashMap<>();
        dependances.put("postgresql", etatBaseDeDonnees());

        EtatSante global = dependances.containsValue(EtatSante.MORT) ? EtatSante.MORT : EtatSante.OK;

        return new ReponseSante("planif-coeur", version, global, dependances, OffsetDateTime.now(horloge));
    }

    private EtatSante etatBaseDeDonnees() {
        try {
            jdbc.queryForObject("SELECT 1", Integer.class);
            return EtatSante.OK;
        } catch (RuntimeException e) {
            LOG.warn("Base de donnees injoignable : {}", e.getMessage());
            return EtatSante.MORT;
        }
    }
}
