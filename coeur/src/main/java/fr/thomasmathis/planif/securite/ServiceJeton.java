package fr.thomasmathis.planif.securite;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.util.Date;

import javax.crypto.SecretKey;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.utilisateurs.Role;
import fr.thomasmathis.planif.utilisateurs.Utilisateur;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;

/**
 * Emission et verification des jetons.
 *
 * <p>Deux types de jetons : un jeton d'acces court, porte a chaque requete, et
 * un jeton de rafraichissement long. Le second ne donne acces a rien d'autre
 * qu'a l'obtention d'un nouveau jeton d'acces : c'est le champ {@code usage}
 * qui les distingue, verifie a chaque lecture.</p>
 */
@Service
public class ServiceJeton {

    public static final String USAGE_ACCES = "acces";
    public static final String USAGE_RAFRAICHISSEMENT = "rafraichissement";

    private final SecretKey cle;
    private final Clock horloge;
    private final Duration dureeAcces;
    private final Duration dureeRafraichissement;

    public ServiceJeton(Clock horloge,
                        @Value("${planif.securite.secret-jwt}") String secret,
                        @Value("${planif.securite.duree-acces-minutes:30}") long dureeAccesMinutes,
                        @Value("${planif.securite.duree-rafraichissement-jours:30}") long dureeRafraichissementJours) {
        byte[] octets = secret.getBytes(StandardCharsets.UTF_8);
        if (octets.length < 32) {
            throw new IllegalStateException(
                    "planif.securite.secret-jwt doit faire au moins 32 caracteres. "
                            + "Generer avec : openssl rand -base64 48");
        }
        this.cle = Keys.hmacShaKeyFor(octets);
        this.horloge = horloge;
        this.dureeAcces = Duration.ofMinutes(dureeAccesMinutes);
        this.dureeRafraichissement = Duration.ofDays(dureeRafraichissementJours);
    }

    public String emettreAcces(Utilisateur utilisateur) {
        return emettre(utilisateur, USAGE_ACCES, dureeAcces);
    }

    public String emettreRafraichissement(Utilisateur utilisateur) {
        return emettre(utilisateur, USAGE_RAFRAICHISSEMENT, dureeRafraichissement);
    }

    public Duration dureeAcces() {
        return dureeAcces;
    }

    private String emettre(Utilisateur utilisateur, String usage, Duration duree) {
        Date maintenant = Date.from(horloge.instant());
        return Jwts.builder()
                .subject(utilisateur.getIdentifiant())
                .claim("uid", utilisateur.getId())
                .claim("role", utilisateur.getRole().name())
                .claim("usage", usage)
                .issuedAt(maintenant)
                .expiration(Date.from(horloge.instant().plus(duree)))
                .signWith(cle)
                .compact();
    }

    /** Lit un jeton et verifie qu'il correspond bien a l'usage attendu. */
    public JetonLu lire(String jeton, String usageAttendu) {
        try {
            Claims claims = Jwts.parser()
                    .verifyWith(cle)
                    .clock(() -> Date.from(horloge.instant()))
                    .build()
                    .parseSignedClaims(jeton)
                    .getPayload();

            String usage = claims.get("usage", String.class);
            if (!usageAttendu.equals(usage)) {
                throw new ExceptionMetier("JETON_INVALIDE", HttpStatus.UNAUTHORIZED,
                        "Ce jeton ne peut pas etre utilise ici");
            }
            return new JetonLu(
                    claims.get("uid", Long.class),
                    claims.getSubject(),
                    Role.valueOf(claims.get("role", String.class)));
        } catch (JwtException | IllegalArgumentException e) {
            throw new ExceptionMetier("JETON_INVALIDE", HttpStatus.UNAUTHORIZED,
                    "Jeton absent, expire ou invalide");
        }
    }

    public record JetonLu(Long utilisateurId, String identifiant, Role role) {
    }
}
